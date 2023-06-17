// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, stdError} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed tokenAddress, uint256 amount);


    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /////////////////////////////////
    ///// Constructor Test //////////
    /////////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

    }

    /////////////////////////////////
    //////// Price Test /////////////
    /////////////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedEth = 0.05 ether;
        uint256 actualEth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedEth, actualEth);
    }

    /////////////////////////////////
    //// Deposit Collateral Test ////
    /////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testEventEmition() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectEmit(true, true, true, false);
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertTransferFailed() public {
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /////////////////////////////////
    //////// Mint DSC Test //////////
    /////////////////////////////////

    function testMintDSCRevertHealthFactorBroken() public depositedCollateral {
        uint256 amountToMint = 10001 ether;
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testMintDSCNotZero() public depositedCollateral{
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testMintDSCCorrectAmount() public depositedCollateral {
        uint256 amountToMint = 9999 ether;
        uint256 startingDSCBalance = dsc.balanceOf(USER);
        vm.startPrank(USER);
        dsce.mintDsc(amountToMint);
        uint256 endingDSCBalance = dsc.balanceOf(USER);
        vm.stopPrank();
        assertEq(amountToMint, endingDSCBalance-startingDSCBalance);
    }

    /////////////////////////////////
    //////// Burn DSC Test //////////
    /////////////////////////////////

    modifier depositCollateralAndMintDSC(uint256 amountToMint){
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
        _;
    }

    function testBurnDSCRevertNoEnoughDSC() public {
        uint256 amountToBurn = 1 ether;
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountToBurn);
        vm.expectRevert(stdError.arithmeticError);
        dsce.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    function testBurnDSCRevertMoreThanZero() public {
        uint256 amountToBurn = 0 ether;
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountToBurn);
        vm.expectRevert(DSCEngine.NeedsMoreThanZero.selector);
        dsce.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    function testBurnDSCRevertHealthFactorBroken() public depositCollateralAndMintDSC(8000 ether) {
        vm.startPrank(USER);
        int256 newEthPrice = 1000e8;
        uint256 amountToBurn = 1000 ether;
        (uint80 roundId,, uint256 startedAt, uint256 updatedAt,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        MockV3Aggregator(ethUsdPriceFeed).updateRoundData(roundId, newEthPrice, updatedAt, startedAt);
        dsc.approve(address(dsce), amountToBurn);
        vm.expectRevert();
        //vm.expectRevert(DSCEngine.BreaksHealthFactor.selector);
        dsce.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    function testBurnDSCSuccess() public depositCollateralAndMintDSC(5000 ether){
        uint256 amountDscToBurn = 2000 ether;
        vm.startPrank(USER);
        uint256 startingHealthFactor = dsce.getHealthFactor(USER);
        dsc.approve(address(dsce), amountDscToBurn);
        dsce.burnDsc(amountDscToBurn);
        uint256 endingHealthFactor = dsce.getHealthFactor(USER);
        vm.stopPrank();
        bool healthfactorComparison = endingHealthFactor > startingHealthFactor;
        assertTrue(healthfactorComparison);
    }

    /////////////////////////////////
    //// Redeem Collateral Test /////
    /////////////////////////////////

    function testRedeemCollateralRevertZeroAmount() public{
        vm.startPrank(USER);
        uint256 amountToRedeem = 0 ether;
        vm.expectRevert(DSCEngine.NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertHealthFactorBroken() depositCollateralAndMintDSC(8000 ether) public{
        vm.startPrank(USER);
        uint256 amountToRedeem = 8 ether;
        vm.expectRevert();
        dsce.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();
    }

    function testRedeemCollateralEmitEvent() depositCollateralAndMintDSC(5000 ether) public{
        vm.startPrank(USER);
        uint256 amountToRedeem = 1 ether;
        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(USER, USER, weth, amountToRedeem);
        dsce.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();
    }

    function testRedeemCollateralSucces() public depositCollateralAndMintDSC(5000 ether){
        vm.startPrank(USER);
        uint256 startingEthAmount = ERC20Mock(weth).balanceOf(USER);
        uint256 amountToRedeem = 1 ether;
        dsce.redeemCollateral(weth, amountToRedeem);
        uint256 endingEthAmount = ERC20Mock(weth).balanceOf(USER);
        vm.stopPrank();
        assertEq(endingEthAmount, startingEthAmount + amountToRedeem);
    }

    /////////////////////////////////
    /////// Liquidation Test ////////
    /////////////////////////////////

    modifier userBreakHealthFactor {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(9000 ether);
        int256 newEthPrice = 1000e8;
        (uint80 roundId,, uint256 startedAt, uint256 updatedAt,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        MockV3Aggregator(ethUsdPriceFeed).updateRoundData(roundId, newEthPrice, updatedAt, startedAt);
        vm.stopPrank();
        _;
    }

    function testLiquidationRevertMoreThanZero() public userBreakHealthFactor{
        vm.startPrank(LIQUIDATOR);
        uint256 amountToLiquidate = 0 ether;
        vm.expectRevert(DSCEngine.NeedsMoreThanZero.selector);
        dsce.liquidate(weth, USER, amountToLiquidate);
        vm.stopPrank();
    }

    function testLiquidationRevertHealthFactorOk() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(9000 ether);
        vm.stopPrank();
        uint256 amountDebtToCover = 1 ether;
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.HealthFactorOK.selector);
        dsce.liquidate(weth, USER, amountDebtToCover);
        vm.stopPrank();
    }
        
    function testLiquidationHealthFactorNotImproved() public {}

    function testLiquidationRevertHealthFactorBroken() public {}

    function testLiquidationSuccess() public userBreakHealthFactor{

    }
}