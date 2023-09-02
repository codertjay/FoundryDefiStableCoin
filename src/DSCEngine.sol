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
    error DSCEngine__HealthFactorIsBelowMinimum(uint256 healthFactor);
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
    uint256 private constant LIQUIDATION_PRECISION = 10;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMint) private s_DSCMinted;
    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////////////
    // EVENT   ///
    ////////////////////////////////////
    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

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
    * @params amountCollateral The amount of decentralized and mint DSC
    * @notice this function will deposit your collateral and mint DSC in one transfer
    */

    function depositCollateralAndMintDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSC)
    external {

        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDSC);
    }

    /*
    * @params tokenCollateralAddress The address of the token to deposit as collateral
    * @params tokenCollateral The amount of collateral to deposit
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
    external
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
    * @param tokenCollateralAddress the collateral address to redeem
    * @param amountCollateral the amount of collateral to redeem
    * @param amountDSCToBurn the amount of dsc to burn
    * This function burn DSC and redeems underlying collateral in one transaction

    */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
    external {
        burnDsc(amountCollateral);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeem collateral already checks health factor
    }

    // in order to redeem collateral:
    // 1. health factor must be over 1 after collateral pulled
    // CEI: check effects, interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
    external moreThanZero(amountCollateral) nonReentrant {
        // 100 -1000 ( revert)
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(
            msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
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


    function burnDsc(uint256 amount) public moreThanZero(amount) {

        s_DSCMinted[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        // this conditional is hypot... unreachable...
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender); // i don't think this would ever hit....

    }

    // $100 eth backing $50 of DSC
    // $20 eht $50 DSC <-- DSC isnt worth $1!!!

    // if some one is almost under collateralized, we will pay you to liquidate them!
    function liquidate() external {

    }

    function getHealthFactor() external view {}

    ////////////////////////////////////
    // PRIVATE & INTERNAL FUNCTIONS   ///
    ////////////////////////////////////
    /*
    * Returns how close to liquidation the user is
    * If a user goes below 1, they can get liquidated
    */
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
    // PUBLIC & EXTERNAL VIEW FUNCTIONS   ///
    ////////////////////////////////////
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
