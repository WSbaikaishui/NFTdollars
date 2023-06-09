// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.4;


import {ILendPoolLoan} from "../interfaces/ILendPoolLoan.sol";
import {ILendPool} from "../interfaces/ILendPool.sol";
import {DataTypes} from "../libraries/types/DataTypes.sol";
import {WadRayMath} from "../libraries/math/WadRayMath.sol";

import {IERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import {IERC721ReceiverUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import {CountersUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

contract LendPoolLoan is Initializable, ILendPoolLoan, ContextUpgradeable, IERC721ReceiverUpgradeable {
  using WadRayMath for uint256;
  using CountersUpgradeable for CountersUpgradeable.Counter;

  ILendPoolAddressesProvider private _addressesProvider;

  CountersUpgradeable.Counter private _loanIdTracker;
  mapping(uint256 => DataTypes.LoanData) private _loans;

  // nftAsset + nftTokenId => loanId
  mapping(address => mapping(uint256 => uint256)) private _nftToLoanIds;
  mapping(address => uint256) private _nftTotalCollateral;
  mapping(address => mapping(address => uint256)) private _userNftCollateral;

  // interceptor whitelist
  mapping(address => bool) private _loanRepaidInterceptorWhitelist;
  // Mapping from token to approved burn interceptor addresses
  mapping(address => mapping(uint256 => address[])) private _loanRepaidInterceptors;
  // locker whitelist
  mapping(address => bool) private _flashLoanLockerWhitelist;
  mapping(address => uint256[]) addressLoans;

  /**
   * @dev Only lending pool can call functions marked by this modifier
   **/
  modifier onlyLendPool() {
    require(_msgSender() == address(_getLendPool()), Errors.CT_CALLER_MUST_BE_LEND_POOL);
    _;
  }
  // called once by the factory at time of deployment
  function initialize(ILendPoolAddressesProvider provider) external initializer {
    __Context_init();

    _addressesProvider = provider;

    // Avoid having loanId = 0
    _loanIdTracker.increment();

    emit Initialized(address(_getLendPool()));
  }

//   function initNft(address nftAsset, address bNftAddress) external override onlyLendPool {
//     IERC721Upgradeable(nftAsset).setApprovalForAll(bNftAddress, true);
//   }

  /**
   * @inheritdoc ILendPoolLoan
   */
  function createLoan(
    address initiator,
    address onBehalfOf,
    address nftAsset,
    uint256 nftTokenId,
    uint256 amount,
  ) external override onlyLendPool returns (uint256) {
    require(_nftToLoanIds[nftAsset][nftTokenId] == 0, Errors.LP_NFT_HAS_USED_AS_COLLATERAL);

    uint256 loanId = _loanIdTracker.current();
    _loanIdTracker.increment();

    _nftToLoanIds[nftAsset][nftTokenId] = loanId;

    // transfer underlying NFT asset to pool and mint bNFT to onBehalfOf
    IERC721Upgradeable(nftAsset).safeTransferFrom(_msgSender(), address(this), nftTokenId);

    // Save Info
    DataTypes.LoanData storage loanData = _loans[loanId];
    loanData.loanId = loanId;
    loanData.state = DataTypes.LoanState.Active;
    loanData.borrower = onBehalfOf;
    loanData.nftAsset = nftAsset;
    loanData.nftTokenId = nftTokenId;
    loanData.amont = amount;

    _userNftCollateral[onBehalfOf][nftAsset] += 1;

    _nftTotalCollateral[nftAsset] += 1;

    emit LoanCreated(initiator, onBehalfOf, loanId, nftAsset, nftTokenId, amount);
    addressLoans[_msgSender()].push(loadId);
    return (loanId);
  }

  /**
   * @inheritdoc ILendPoolLoan
   */
  function updateLoan(
    address initiator,
    uint256 loanId,
    uint256 amountAdded,
  ) external override onlyLendPool {
    // Must use storage to change state
    DataTypes.LoanData storage loan = _loans[loanId];

    // Ensure valid loan state
    require(loan.state == DataTypes.LoanState.Active, "LPL_INVALID_LOAN_STATE");

    uint256 amountScaled = 0;
    loan.amount += amountAdded;

    emit LoanUpdated(
      initiator,
      loanId,
      loan.nftAsset,
      loan.nftTokenId,
      amountAdded,
    );
  }

  /**
   * @inheritdoc ILendPoolLoan
   */
  function repayLoan(
    address initiator,
    uint256 loanId,
    uint256 amount,
  ) external override onlyPool {
    // Must use storage to change state
    DataTypes.LoanData storage loan = _loans[loanId];

    // Ensure valid loan state
    require(loan.state == DataTypes.LoanState.Active,"Loan is not active");

    _handleBeforeLoanRepaid(loan.nftAsset, loan.nftTokenId);

    // state changes and cleanup
    // NOTE: these must be performed before assets are released to prevent reentrance
    _loans[loanId].state = DataTypes.LoanState.Repaid;

    _nftToLoanIds[loan.nftAsset][loan.nftTokenId] = 0;

    require(_userNftCollateral[loan.borrower][loan.nftAsset] >= 1, "LP_INVALIED_USER_NFT_AMOUNT");
    _userNftCollateral[loan.borrower][loan.nftAsset] -= 1;

    require(_nftTotalCollateral[loan.nftAsset] >= 1, "LP_INVALIED_NFT_AMOUNT");
    _nftTotalCollateral[loan.nftAsset] -= 1;

    IERC721Upgradeable(loan.nftAsset).safeTransferFrom(address(this), _msgSender(), loan.nftTokenId);

    emit LoanRepaid(initiator, loanId, loan.nftAsset, loan.nftTokenId,  amount);

    _handleAfterLoanRepaid(loan.nftAsset, loan.nftTokenId);
  }


  /**
   * @inheritdoc ILendPoolLoan
   */
  function liquidateLoan(
    address initiator,
    uint256 loanId,
    uint256 borrowAmount,
  ) external override onlyLendPool {
    // Must use storage to change state
    DataTypes.LoanData storage loan = _loans[loanId];

    // Ensure valid loan state
    require(loan.state == DataTypes.LoanState.Auction, "LPL_INVALID_LOAN_STATE");

    _handleBeforeLoanRepaid(loan.nftAsset, loan.nftTokenId);

    // state changes and cleanup
    // NOTE: these must be performed before assets are released to prevent reentrance
    _loans[loanId].state = DataTypes.LoanState.Defaulted;

    _nftToLoanIds[loan.nftAsset][loan.nftTokenId] = 0;

    require(_userNftCollateral[loan.borrower][loan.nftAsset] >= 1, "LP_INVALIED_USER_NFT_AMOUNT");
    _userNftCollateral[loan.borrower][loan.nftAsset] -= 1;

    require(_nftTotalCollateral[loan.nftAsset] >= 1, "LP_INVALIED_NFT_AMOUNT");
    _nftTotalCollateral[loan.nftAsset] -= 1;
    IERC721Upgradeable(loan.nftAsset).safeTransferFrom(address(this), _msgSender(), loan.nftTokenId);
    emit LoanLiquidated(
      initiator,
      loanId,
      loan.nftAsset,
      loan.nftTokenId,
      borrowAmount,
    );

    _handleAfterLoanRepaid(loan.nftAsset, loan.nftTokenId);
  }

  function onERC721Received(
    address operator,
    address from,
    uint256 tokenId,
    bytes calldata data
  ) external pure override returns (bytes4) {
    operator;
    from;
    tokenId;
    data;
    return IERC721ReceiverUpgradeable.onERC721Received.selector;
  }

  function borrowerOf(uint256 loanId) external view override returns (address) {
    return _loans[loanId].borrower;
  }

  function getCollateralLoanId(address nftAsset, uint256 nftTokenId) external view override returns (uint256) {
    return _nftToLoanIds[nftAsset][nftTokenId];
  }

  function getLoan(uint256 loanId) external view override returns (DataTypes.LoanData memory loanData) {
    return _loans[loanId];
  }

  function getLoanCollateralAndReserve(uint256 loanId)
    external
    view
    override
    returns (
      address nftAsset,
      uint256 nftTokenId,
      uint256 amount
    )
  {
    return (
      _loans[loanId].nftAsset,
      _loans[loanId].nftTokenId,
      _loans[loanId].amount
    );
  }

  function getNftCollateralAmount(address nftAsset) external view override returns (uint256) {
    return _nftTotalCollateral[nftAsset];
  }

  function getUserNftCollateralAmount(address user, address nftAsset) external view override returns (uint256) {
    return _userNftCollateral[user][nftAsset];
  }

  function getCurrentLoanId() public view returns (uint256) {
    return _loanIdTracker.current();
  }

  function _getLendPool() internal view returns (ILendPool) {
    return ILendPool(_addressesProvider.getLendPool());
  }

}
