//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";

import "../../storage/Account.sol";
import "../../storage/Pool.sol";

import "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";

import "../../interfaces/IVaultModule.sol";

/**
 * @title Allows accounts to delegate collateral to a pool.
 * @dev See IVaultModule.
 */
contract VaultModule is IVaultModule {
    using SetUtil for SetUtil.UintSet;
    using SetUtil for SetUtil.Bytes32Set;
    using SetUtil for SetUtil.AddressSet;
    using DecimalMath for uint256;
    using Pool for Pool.Data;
    using Vault for Vault.Data;
    using VaultEpoch for VaultEpoch.Data;
    using Collateral for Collateral.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using AccountRBAC for AccountRBAC.Data;
    using Distribution for Distribution.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using ScalableMapping for ScalableMapping.Data;
    using SafeCastU128 for uint128;
    using SafeCastU256 for uint256;
    using SafeCastI128 for int128;
    using SafeCastI256 for int256;

    bytes32 private constant _DELEGATE_FEATURE_FLAG = "delegateCollateral";
    bytes32 private constant _MIGRATE_DELEGATION_FEATURE_FLAG = "migrateDelegation";

    /**
     * @inheritdoc IVaultModule
     */
    function delegateCollateral(
        uint128 accountId,
        uint128 poolId,
        address collateralType,
        uint256 newCollateralAmountD18,
        uint256 leverage
    ) external override {
        FeatureFlag.ensureAccessToFeature(_DELEGATE_FEATURE_FLAG);
        Account.loadAccountAndValidatePermission(accountId, AccountRBAC._DELEGATE_PERMISSION);

        // Each collateral type may specify a minimum collateral amount that can be delegated.
        // See CollateralConfiguration.minDelegationD18.
        if (newCollateralAmountD18 > 0) {
            CollateralConfiguration.requireSufficientDelegation(
                collateralType,
                newCollateralAmountD18
            );
        }

        // System only supports leverage of 1.0 for now.
        if (leverage != DecimalMath.UNIT) revert InvalidLeverage(leverage);

        // Identify the vault that corresponds to this collateral type and pool id.
        Vault.Data storage vault = Pool.loadExisting(poolId).vaults[collateralType];

        uint256 currentCollateralAmount = vault.currentAccountCollateral(accountId);

        // Conditions for collateral amount

        // Ensure current collateral amount differs from the new collateral amount.
        if (newCollateralAmountD18 == currentCollateralAmount) {
            revert InvalidCollateralAmount();
        }
        // If increasing delegated collateral amount,
        // Check that the account has sufficient collateral.
        else if (newCollateralAmountD18 > currentCollateralAmount) {
            // Check if the collateral is enabled here because we still want to allow reducing delegation for disabled collaterals.
            CollateralConfiguration.collateralEnabled(collateralType);

            Account.requireSufficientCollateral(
                accountId,
                collateralType,
                newCollateralAmountD18 - currentCollateralAmount
            );

            Pool.loadExisting(poolId).checkPoolCollateralLimit(
                collateralType,
                newCollateralAmountD18 - currentCollateralAmount
            );

            // if decreasing delegation amount, ensure min time has elapsed
        } else {
            Pool.loadExisting(poolId).requireMinDelegationTimeElapsed(
                accountId,
                vault.currentEpoch().lastDelegationTime[accountId]
            );
        }

        // distribute any outstanding rewards distributor value to vaults prior to updating positions
        Pool.load(poolId).updateRewardsToVaults(
            Vault.PositionSelector(accountId, poolId, collateralType)
        );

        // Update the account's position for the given pool and collateral type,
        // Note: This will trigger an update in the entire debt distribution chain.
        uint256 collateralPrice = _updatePosition(
            accountId,
            poolId,
            collateralType,
            newCollateralAmountD18,
            currentCollateralAmount,
            leverage
        );

        _verifyPoolCratio(poolId, collateralType);

        // If decreasing the delegated collateral amount,
        // check the account's collateralization ratio.
        // Note: This is the best time to do so since the user's debt and the collateral's price have both been updated.
        if (newCollateralAmountD18 < currentCollateralAmount) {
            int256 debt = vault.currentEpoch().consolidatedDebtAmountsD18[accountId];

            uint256 minIssuanceRatioD18 = Pool
                .loadExisting(poolId)
                .collateralConfigurations[collateralType]
                .issuanceRatioD18;

            // Minimum collateralization ratios are configured in the system per collateral type.abi
            // Ensure that the account's updated position satisfies this requirement.
            CollateralConfiguration.load(collateralType).verifyIssuanceRatio(
                debt,
                newCollateralAmountD18.mulDecimal(collateralPrice),
                minIssuanceRatioD18
            );

            // Accounts cannot reduce collateral if any of the pool's
            // connected market has its capacity locked.
            _verifyNotCapacityLocked(poolId);
        }

        // solhint-disable-next-line numcast/safe-cast
        vault.currentEpoch().lastDelegationTime[accountId] = uint64(block.timestamp);

        emit DelegationUpdated(
            accountId,
            poolId,
            collateralType,
            newCollateralAmountD18,
            leverage,
            ERC2771Context._msgSender()
        );
    }

    /**
     * @inheritdoc IVaultModule
     */
    function migrateDelegation(
        uint128 accountId,
        uint128 oldPoolId,
        address collateralType,
        uint128 newPoolId
    ) external override {
        if (oldPoolId == newPoolId) {
            revert ParameterError.InvalidParameter("newPoolId", "must differ from oldPoolId");
        }
        FeatureFlag.ensureAccessToFeature(_MIGRATE_DELEGATION_FEATURE_FLAG);
        Account.loadAccountAndValidatePermission(accountId, AccountRBAC._DELEGATE_PERMISSION);

        // Identify the vault that corresponds to this collateral type and old pool id.
        Vault.Data storage oldVault = Pool.loadExisting(oldPoolId).vaults[collateralType];
        Vault.Data storage newVault = Pool.loadExisting(newPoolId).vaults[collateralType];

        uint256 currentCollateralAmount = oldVault.currentAccountCollateral(accountId);

        if (newVault.currentAccountCollateral(accountId) > 0) {
            // for now to keep things a bit simpler it is not possible to migrate delegation to a pool thats
            // already delegated
            revert ParameterError.InvalidParameter("newPoolId", "already delegated");
        }

        // Cannot migrate 0 collateral amount
        if (currentCollateralAmount == 0) {
            revert ParameterError.InvalidParameter("oldPoolId", "not delegated");
        }

        int256 currentDebtAmount = Pool.load(oldPoolId).updateAccountDebt(
            collateralType,
            accountId
        );

        // Cannot migrate if min delegation time has not elapsed
        Pool.loadExisting(oldPoolId).requireMinDelegationTimeElapsed(
            accountId,
            oldVault.currentEpoch().lastDelegationTime[accountId]
        );

        // Must not surpass collateral limit of new pool
        Pool.loadExisting(newPoolId).checkPoolCollateralLimit(
            collateralType,
            currentCollateralAmount
        );

        // distribute any outstanding rewards distributor value to vaults prior to updating positions
        Pool.load(oldPoolId).updateRewardsToVaults(
            Vault.PositionSelector(accountId, oldPoolId, collateralType)
        );
        Pool.load(newPoolId).updateRewardsToVaults(
            Vault.PositionSelector(accountId, newPoolId, collateralType)
        );

        // Clear debt for account in preparation for movement to new pool
        Pool.load(oldPoolId).assignDebtToAccount(collateralType, accountId, -currentDebtAmount);
        Pool.load(newPoolId).updateAccountDebt(collateralType, accountId);

        // Update the account's position for the given pool and collateral type,
        _updateAccountCollateralPools(accountId, oldPoolId, collateralType, false);
        _updateAccountCollateralPools(accountId, newPoolId, collateralType, true);

        oldVault.currentEpoch().updateAccountPosition(accountId, 0, 1 ether);
        newVault.currentEpoch().updateAccountPosition(accountId, currentCollateralAmount, 1 ether);

        Pool.load(oldPoolId).recalculateVaultCollateral(collateralType);
        uint256 collateralPrice = Pool.load(newPoolId).recalculateVaultCollateral(collateralType);

        // old pool must not be left in capacity locked state
        _verifyNotCapacityLocked(oldPoolId);

        // newly migrated position must not be liquidatable
        CollateralConfiguration.load(collateralType).verifyLiquidationRatio(
            currentDebtAmount,
            currentCollateralAmount.mulDecimal(collateralPrice)
        );

        // now assign the new debt to the account
        Pool.load(newPoolId).assignDebtToAccount(collateralType, accountId, currentDebtAmount);

        // solhint-disable-next-line numcast/safe-cast
        oldVault.currentEpoch().lastDelegationTime[accountId] = uint64(block.timestamp);
        // solhint-disable-next-line numcast/safe-cast
        newVault.currentEpoch().lastDelegationTime[accountId] = uint64(block.timestamp);

        _verifyPoolCratio(oldPoolId, collateralType);
        _verifyPoolCratio(newPoolId, collateralType);

        emit DelegationUpdated(
            accountId,
            oldPoolId,
            collateralType,
            0,
            1 ether,
            ERC2771Context._msgSender()
        );
        emit DelegationUpdated(
            accountId,
            newPoolId,
            collateralType,
            currentCollateralAmount,
            1 ether,
            ERC2771Context._msgSender()
        );
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getPositionCollateralRatio(
        uint128 accountId,
        uint128 poolId,
        address collateralType
    ) external override returns (uint256) {
        return Pool.load(poolId).currentAccountCollateralRatio(collateralType, accountId);
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getVaultCollateralRatio(
        uint128 poolId,
        address collateralType
    ) external override returns (uint256) {
        return Pool.load(poolId).currentVaultCollateralRatio(collateralType);
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getPositionCollateral(
        uint128 accountId,
        uint128 poolId,
        address collateralType
    ) external view override returns (uint256 amount) {
        return Pool.load(poolId).vaults[collateralType].currentAccountCollateral(accountId);
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getPosition(
        uint128 accountId,
        uint128 poolId,
        address collateralType
    )
        external
        override
        returns (
            uint256 collateralAmount,
            uint256 collateralValue,
            int256 debt,
            uint256 collateralizationRatio
        )
    {
        Pool.Data storage pool = Pool.load(poolId);

        debt = pool.updateAccountDebt(collateralType, accountId);
        pool.rebalanceMarketsInPool();
        (collateralAmount, collateralValue) = pool.currentAccountCollateral(
            collateralType,
            accountId
        );
        collateralizationRatio = pool.currentAccountCollateralRatio(collateralType, accountId);
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getPositionDebt(
        uint128 accountId,
        uint128 poolId,
        address collateralType
    ) external override returns (int256 debt) {
        Pool.Data storage pool = Pool.loadExisting(poolId);
        debt = pool.updateAccountDebt(collateralType, accountId);
        pool.rebalanceMarketsInPool();
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getVaultCollateral(
        uint128 poolId,
        address collateralType
    ) public view override returns (uint256 amount, uint256 value) {
        return Pool.loadExisting(poolId).currentVaultCollateral(collateralType);
    }

    /**
     * @inheritdoc IVaultModule
     */
    function getVaultDebt(uint128 poolId, address collateralType) public override returns (int256) {
        return Pool.loadExisting(poolId).currentVaultDebt(collateralType);
    }

    function getLastDelegationTime(
        uint128 accountId,
        uint128 poolId,
        address collateralType
    ) external view override returns (uint256 lastDelegationTime) {
        return
            Pool.loadExisting(poolId).vaults[collateralType].currentEpoch().lastDelegationTime[
                accountId
            ];
    }

    /**
     * @dev Updates the given account's position regarding the given pool and collateral type,
     * with the new amount of delegated collateral.
     *
     * The update will be reflected in the registered delegated collateral amount,
     * but it will also trigger updates to the entire debt distribution chain.
     */
    function _updatePosition(
        uint128 accountId,
        uint128 poolId,
        address collateralType,
        uint256 newCollateralAmount,
        uint256 oldCollateralAmount,
        uint256 leverage
    ) internal returns (uint256 collateralPrice) {
        Pool.Data storage pool = Pool.load(poolId);

        // Trigger an update in the debt distribution chain to make sure that
        // the user's debt is up to date.
        pool.updateAccountDebt(collateralType, accountId);

        // Get the collateral entry for the given account and collateral type.
        Collateral.Data storage collateral = Account.load(accountId).collaterals[collateralType];

        // Adjust collateral depending on increase/decrease of amount.
        if (newCollateralAmount > oldCollateralAmount) {
            collateral.decreaseAvailableCollateral(newCollateralAmount - oldCollateralAmount);
        } else {
            collateral.increaseAvailableCollateral(oldCollateralAmount - newCollateralAmount);
        }

        // If the collateral amount is not negative, make sure that the pool exists
        // in the collateral entry's pool array. Otherwise remove it.
        _updateAccountCollateralPools(accountId, poolId, collateralType, newCollateralAmount > 0);

        // Update the account's position in the vault data structure.
        pool.vaults[collateralType].currentEpoch().updateAccountPosition(
            accountId,
            newCollateralAmount,
            leverage
        );

        // Trigger another update in the debt distribution chain,
        // and surface the latest price for the given collateral type (which is retrieved in the update).
        collateralPrice = pool.recalculateVaultCollateral(collateralType);
    }

    function _verifyNotCapacityLocked(uint128 poolId) internal view {
        Pool.Data storage pool = Pool.load(poolId);

        Market.Data storage market = pool.findMarketWithCapacityLocked();

        if (market.id > 0) {
            revert CapacityLocked(market.id);
        }
    }

    function _verifyPoolCratio(uint128 poolId, address collateralType) internal {
        Pool.Data storage pool = Pool.load(poolId);
        int256 rawVaultDebt = pool.currentVaultDebt(collateralType);
        (, uint256 collateralValue) = pool.currentVaultCollateral(collateralType);
        if (
            rawVaultDebt > 0 &&
            collateralValue.divDecimal(rawVaultDebt.toUint()) <
            CollateralConfiguration.load(collateralType).liquidationRatioD18
        ) {
            revert InsufficientVaultCollateralRatio(poolId, collateralType);
        }
    }

    /**
     * @dev Registers the pool in the given account's collaterals array.
     */
    function _updateAccountCollateralPools(
        uint128 accountId,
        uint128 poolId,
        address collateralType,
        bool added
    ) internal {
        Collateral.Data storage depositedCollateral = Account.load(accountId).collaterals[
            collateralType
        ];

        bool containsPool = depositedCollateral.pools.contains(poolId);
        if (added && !containsPool) {
            depositedCollateral.pools.add(poolId);
        } else if (!added && containsPool) {
            depositedCollateral.pools.remove(poolId);
        }
    }
}
