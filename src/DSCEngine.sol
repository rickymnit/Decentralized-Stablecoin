// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import { OracleLib } from "./libraries/OracleLib.sol";
import { AggregatorV3Interface } from "../lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { DecentralizedStableCoin } from "./DecentralizedStableCoin.sol";
/*
 * @title DSCEngine
 * @author Ricky Raj
 * the system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg
 * This stablecoin has the properties:
 * - Exogeneous(ETH & BTC)
 * - Stability Mechanism (Minting): Algorithmic
 * - Relative Stability: Anchored or Pegged ($)
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH and wBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC system. It hadles all the logic for mining and redeeming DSC, as well as depositing & wihtdrawing collateral.
 * @notice This contract is very loosley based on the MakerDAO DSS (DAI) system.
*/
contract DSCEngine is ReentrancyGuard{
    // Errors-------------xxxxxx-------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 _healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthNotImproved();

    // State Variables -------------xxxxxx-------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; 
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONOUS = 10; // 10 % bonus

    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; 
    address [] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;


    // Events-------------xxxxxx------------------------------------------------------------------------------------------------------------------------------------------------------------------------- 
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

    // modifiers-------------xxxxxx-------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    modifier moreThanZero(uint256 amount){
        if(amount == 0){
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }
    modifier isAllowedToken(address token){
        if(s_priceFeeds[token] == address(0)){
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    // Functions-------------xxxxxx-------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds. 
        if(tokenAddresses.length != priceFeedAddresses.length){
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
        }
        // For example ETH/USD, BTC/USD, MKR/USD etc.
        for (uint256 i = 0; i<tokenAddresses.length; i++){
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // External Functions-------------xxxxxx-------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    
    /*
     *@param tokenCollateralAddress The address of the token to deposit as Collateral
     *@param amountCollateral The amount of collateral to deposit.
     *@param amountDscToMint The amount of decentralized stablecoin to mint.
     *@notice this function will deposit your collateral and mint DSC in one transection
    */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external{
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice follows CEI(Check Effects Interactions)
     * @param tokenCollateralAddress The address of the token to deposit as Collateral
     * @param amountCollateral The amount of collateral to deposit.
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this),amountCollateral);
        if (!success){
            revert DSCEngine__TransferFailed();
        }
    }


    /*
     * @notice follows CEI(Check Effects Interactions).
     * @param tokenCollateralAddress The address of the token to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @param This function burns DSC and redeem underlying collateralin one transection.
    */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external{
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral() already checks health factor
    }

    // in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant{
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }


    /*
     * @notice follows CEI(Check Effects Interactions)
     * @param amountDscToMint The amount of the decentralized stablecoin to mint.
     * @notice they must have more collateral value than the minimum threshold
    */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much ($150 DSC form $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted){
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(msg.sender,msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender); // I dont think this would ever hit....
    }

    // If we do start nearing undercollaterlization, we need someone to luquidate positions 
    
    // $100 ETH backing $50 DSC
    // $20 ETH back $50 DSC <- DSC isn't worth $1!!!
    
    // $75 ETH backing $50 DSC
    // Liquidator take $75 backing and burns off the $50 DSC
    
    // If someone is almost undercollateralized, we will pay to liquidate them!

    /*
     * @param collateral the ERC20 collateral address to liquidate from the user.
     * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover the amount of DSC you want to burn to  improve users health factor.
     * 
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this to work.
     * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOk();
        }

        // We want to burn their DSC "debt"
        // And take their collateral 
        // Bad User: $140 ETH, $100 DSC
        //debtToCover = $100
        // $100 of DSC == ?? ETH?
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement t feature to liquidate in the event the protocol is insolvent
        // And swap extra amounts into a treasury

        // 0.5 * 0.1 = 0.005 getting 0.055;
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONOUS) /  LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(user, msg.sender, debtToCover);

        uint256 endingUserHealthFator = _healthFactor(user);
        if(endingUserHealthFator <= startingUserHealthFactor){
            revert DSCEngine__HealthNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view{}

    // Private and Internal Functions-------------xxxxxx-------------------------------------------------------------------------------------------------------------------------------------------------------------------------

    /* 
     * @dev Low level internal function, do nit call unless the function calling it is safe
     * checking fot health factor being broken
     */
    function _burnDsc( address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This condition is hypothtically unreachable
        if(!success){
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private{
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success){
            revert DSCEngine__TransferFailed();
        }

    }
    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /*
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
    */
    function _healthFactor(address user) private view returns(uint256){
        // total DSC minted 
        // total collateral Value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;  //(collateralValueInUsd * LIQUIDATION_THRESHOLD)/100;
        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 50000 / 100 = (500 / 100) < 1

        // $1000 ETH / 100 DSC = 1
        // 150 * 50 = 50000 / 100 = (500 / 100) > 1
        return(collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
    /*
     * check health factor (do they have enough collateral?)
     * Revert if they dont
    */
    function _revertIfHealthFactorIsBroken(address user) internal view{
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR){
            revert DSCEngine__BreakHealthFactor(userHealthFactor);
        }
    }

    // public and External view-------------xxxxxx-------------------------------------------------------------------------------------------------------------------------------------------------------------------------
    
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256){
        // price of ETH(token)
        // $/ETH ETH ??
        // $2000 / ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // (10e18 * 1e18) / (2000e8 *1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }
    
    function getAccountCollateralValue(address user) public view returns(uint256 tokenCollateralValueInUsd){
        // loop through each collateral token, get the amount they have deposited, and map it to 
        // the price, to get the USD value
        for(uint256 i = 0; i < s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            tokenCollateralValueInUsd += getUsdValue(token, amount);
        }
        return tokenCollateralValueInUsd;
    }
    function getUsdValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value form ChainLink will be 1000*1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}