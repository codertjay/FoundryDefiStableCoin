// SPDX-License-Identifier: MIT
// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
/**
 * @title DSCEngine
 * @author Favour Afenikhena
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a
 * 1 token = $1 Peg
 * This stablecoin has the properties:
 * - Exogenous Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "over collateralized" at no point, should the value of all
 *  collateral <= the $ backed value of all DSC.
 *
 * @notice This contract is the core of the Decentralized Stable-coin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    //////////////////
    // Errors   ///
    //////////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedsMustBeEqualLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorIsBelowMinimum(uint256 healthFactor);
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__MintFailed();

    ////////////////////////////////////
    // Modifiers   ///
    ////////////////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }
    ////////////////////////////////////
    // State Declaration ///
    ////////////////////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over collateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // this mean a 10% bonus
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;


    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMint) private s_DSCMinted;
    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////////////
    // EVENT   ///
    ////////////////////////////////////
    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

    ////////////////////////////////////
    // FUNCTIONS   ///
    ////////////////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedsMustBeEqualLength();
        }
        // For example ETH /USD, BTC/USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }
    ////////////////////////////////////
    // EXTERNAL FUNCTIONS   ///
    ////////////////////////////////////

    /*
   * @params tokenCollateralAddress The address of the token to deposit as collateral
    * @params tokenCollateral The amount of collateral to deposit
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
    public
    moreThanZero(amountCollateral)
    isAllowedToken(tokenCollateralAddress)
    nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit collateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
    * @params tokenCollateralAddress The address of the token to deposit as collateral
    * @params tokenCollateral The amount of collateral to deposit
    * @params amountCollateral The amount of decentralized and mint DSC
    * @notice this function will deposit your collateral and mint DSC in one transfer
    */

    function depositCollateralAndMintDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSC)
    external {

        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDSC);
    }

    /*
    * @param tokenCollateralAddress the collateral address to redeem
    * @param amountCollateral the amount of collateral to redeem
    * @param amountDSCToBurn the amount of dsc to burn
    * This function burn DSC and redeems underlying collateral in one transaction

    */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
    external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeem collateral already checks health factor
    }

    // in order to redeem collateral:
    // 1. health factor must be over 1 after collateral pulled
    // CEI: check effects, interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
    public moreThanZero(amountCollateral) nonReentrant {
        // 100 -1000 ( revert)
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        // revert if the health factor is broken
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
    * @notice follows CEI
    * @params amountDSCMint The amount of DecentralizedStableCoin to mint
    * @notice they must have more collateral value than the minimum threshold
    */
    function mintDsc(uint256 amountDSCMint) public moreThanZero(amountDSCMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDSCMint;
        // if they minted too much ( $150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDSCMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // we need to check if this breaks health factor?
    function burnDsc(uint256 amount) public moreThanZero(amount) {

        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // i don't think this would ever hit....
    }

    // $100 eth backing $50 of DSC
    // $20 eht $50 DSC <-- DSC isn't worth $1!!!

    // $75 backing $50 DSC
    // liquidator take $75 backing and burns off the DSC

    // if some one is almost under collateralized, we will pay you to liquidate them!
    /*
    * @param Collateral the erc20 collateral address to liquidate from the user
    * @param user the user who has broken the health factor. the _healthfactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover the amount of DSC you want to improve the users health factor
    * @notice You can partially liquidate a user.@param
    * @notice You will get a liquidation bonus for taking the users funds
    * @notice This function working assumes the protocol will be roughly 200%
    overCollateralized in order for this to work
    * @notice A know bug would be if the protocol were 100% or less collateralized, then we wouldn't
    be able to incentive the liquidate
    * for example, if the price of the collateral plummeted before anyone could be liquidated
    */

    /*
    * Follow CEI
    */
    function liquidate(address collateral, address user, uint256 debtToCover)
    external moreThanZero(debtToCover) nonReentrant {

        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // we want to burn their dsc debt
        // and take their collateral
        // Bad user $140 ETH, $100 DSC
        // debtToCOver = $100
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // and give them a 10% bonus
        // so we are giving the liquidator for $110 of weth for 100 dsc
        // we should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amounts into a treasury
        // 0.05 ETH * 0.1 = 0.005 . Get 0.055 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered * bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // we need to burn to burn dsc
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    ////////////////////////////////////
    // PRIVATE & INTERNAL FUNCTIONS   ///
    ////////////////////////////////////
    /*
    * Returns how close to liquidation the user is
    * If a user goes below 1, they can get liquidated
    */

    /*
    * @dev Low-level internal function, do not call unless the function calling it is
    checking if health factor is broken
    */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private
    {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // this conditional is hypot... unreachable...
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address from, address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(
            to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
    private
    view
    returns (uint256 totalDscMinted, uint256 collateralValueInUSD)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        // total dsc minted
        // total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);
        // user dsc minted
        // user collateral value
        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. check health factor (do they have enough collateral?)
        // 2. Revert if they dont
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBelowMinimum(userHealthFactor);
        }

    }

    ////////////////////////////////////
    // PUBLIC & EXTERNAL VIEW FUNCTIONS  ///
    ////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $/ETH ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        //( $10e18 * 1e18) / ($2000e8 * 1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);

    }


    function getAccountCollateralValue(address user) public view returns (uint256) {
        // loop through all the collateral tokens
        uint256 totalCollateralValueInUsd;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }


    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The return value is in 1e8 format, so 1e8 = $1
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
