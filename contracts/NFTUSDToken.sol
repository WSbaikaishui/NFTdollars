// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.4;

import {ILendPool} from "../interfaces/ILendPool.sol";
import {INFTUSD} from "../interfaces/INFTUSDToken.sol";
import {IIncentivesController} from "../interfaces/IIncentivesController.sol";
import {IncentivizedERC20} from "./IncentivizedERC20.sol";
import {WadRayMath} from "../libraries/math/WadRayMath.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/**
 * @title ERC20 NFTUSD
 * @dev Implementation of the interest bearing token for the Bend protocol
 * @author Bend
 */
contract NFTUSDToken is Initializable, INFTUSD, IncentivizedERC20 {
  using WadRayMath for uint256;
  using SafeERC20Upgradeable for IERC20Upgradeable;
  ILendPool public pool;

  modifier onlyLendPool() {
    require(_msgSender() == address(_getLendPool()), Errors.CT_CALLER_MUST_BE_LEND_POOL);
    _;
  }

  /**
   * @dev Initializes the NFTUSD
   * @param addressProvider The address of the address provider where this NFTUSD will be used
   * @param treasury The address of the Bend treasury, receiving the fees on this NFTUSD
   * @param underlyingAsset The address of the underlying asset of this NFTUSD
   */
  function initialize(
    address stabilitypool,
    uint8 NFTUSDDecimals,
    string calldata NFTUSDName,
    string calldata NFTUSDSymbol
  ) external override initializer {
    __IncentivizedERC20_init(NFTUSDName, NFTUSDSymbol, NFTUSDDecimals);

    pool = ILendPool(stabilitypool);

  }

  /**
   * @dev Burns NFTUSDs from `user` and sends the equivalent amount of underlying to `receiverOfUnderlying`
   * - Only callable by the LendPool, as extra state updates there need to be managed
   * @param user The owner of the NFTUSDs, getting them burned
   * @param receiverOfUnderlying The address that will receive the underlying
   * @param amount The amount being burned
   * @param index The new liquidity index of the reserve
   **/
  function burn(
    address user,
    uint256 amount,
  ) external override onlyLendPool {
    _burn(user, amount);
    emit Burn(user, amount);
  }

  /**
   * @dev Mints `amount` NFTUSDs to `user`
   * - Only callable by the LendPool, as extra state updates there need to be managed
   * @param user The address receiving the minted tokens
   * @param amount The amount of tokens getting minted
   * @param index The new liquidity index of the reserve
   * @return `true` if the the previous balance of the user was 0
   */
  function mint(
    address user,
    uint256 amount,
  ) external override onlyLendPool returns (bool) {
    uint256 previousBalance = super.balanceOf(user);
    _mint(user, amount);
    emit Mint(user, amount);
    return previousBalance == 0;
  }


  /**
   * @dev Calculates the balance of the user: principal balance + interest generated by the principal
   * @param user The user whose balance is calculated
   * @return The balance of the user
   **/
  function balanceOf(address user) public view override returns (uint256) {

    return super.balanceOf(user);
  }


  /**
   * @dev calculates the total supply of the specific NFTUSD
   * since the balance of every single user increases over time, the total supply
   * does that too.
   * @return the current total supply
   **/
  function totalSupply() public view override returns (uint256) {
    return super.totalSupply();
  }


  /**
   * @dev Returns the address of the lending pool where this NFTUSD is used
   **/
  function POOL() public view returns (ILendPool) {
    return _getLendPool();
  }

  function _getLendPool() internal view returns (ILendPool) {
    return ILendPool(pool);
  }

  function _getLendPoolConfigurator() internal view returns (ILendPoolConfigurator) {
    return ILendPoolConfigurator(_addressProvider.getLendPoolConfigurator());
  }

  /**
   * @dev Transfers the NFTUSDs between two users. Validates the transfer
   * (ie checks for valid HF after the transfer) if required
   * @param from The source address
   * @param to The destination address
   * @param amount The amount getting transferred
   * @param validate `true` if the transfer needs to be validated
   **/
  function _transfer(
    address from,
    address to,
    uint256 amount,
    bool validate
  ) internal {
    super._transfer(from, to, amount);
    emit BalanceTransfer(from, to, amount);
  }

  /**
   * @dev Overrides the parent _transfer to force validated transfer() and transferFrom()
   * @param from The source address
   * @param to The destination address
   * @param amount The amount getting transferred
   **/
  function _transfer(
    address from,
    address to,
    uint256 amount
  ) internal override {
    _transfer(from, to, amount, true);
  }
}