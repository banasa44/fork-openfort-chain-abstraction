// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IEntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IInvoiceManager} from "../src/interfaces/IInvoiceManager.sol";
import {IVaultManager} from "../src/interfaces/IVaultManager.sol";
import {CheckOrDeployEntryPoint} from "./auxiliary/checkOrDeployEntrypoint.sol";
import {CheckAaveTokenStatus} from "./auxiliary/checkAaveTokenStatus.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpgradeableOpenfortProxy} from "../src/proxy/UpgradeableOpenfortProxy.sol";
import {BaseVault} from "../src/vaults/BaseVault.sol";
import {AaveVault} from "../src/vaults/AaveVault.sol";
import {VaultManager} from "../src/vaults/VaultManager.sol";
import {CABPaymaster} from "../src/paymasters/CABPaymaster.sol";
import {InvoiceManager} from "../src/core/InvoiceManager.sol";

import {ICrossL2Prover} from "@vibc-core-smart-contracts/contracts/interfaces/ICrossL2Prover.sol";

// import {IL2Pool} from "aave-v3-origin/core/contracts/interfaces/IL2Pool.sol";
// import {L2Encoder} from "aave-v3-origin/core/contracts/misc/L2Encoder.sol";

// forge script script/deployChainAbstractionSetup.s.sol:DeployChainAbstractionSetup "[0xusdc, 0xusdt]" --sig "run(address[])" --via-ir --rpc-url=127.0.0.1:854

contract DeployChainAbstractionSetup is
    Script,
    CheckOrDeployEntryPoint,
    CheckAaveTokenStatus
{
    uint256 internal deployerPrivKey = vm.envUint("PK_DEPLOYER");
    uint256 internal withdrawLockBlock = vm.envUint("WITHDRAW_LOCK_BLOCK");
    address internal deployer = vm.addr(deployerPrivKey);
    address internal crossL2Prover = vm.envAddress("CROSS_L2_PROVER");
    address internal owner = vm.envAddress("OWNER");
    address internal verifyingSigner = vm.envAddress("VERIFYING_SIGNER");
    bytes32 internal versionSalt = vm.envBytes32("VERSION_SALT");

    address internal aavePool = vm.envAddress("AAVE_POOL");
    address internal protocolDataProvider = vm.envAddress("AAVE_DATA_PROVIDER");
    address internal l2Encoder = vm.envAddress("L2_ENCODER");

    function run(address[] calldata tokens) public {
        if (tokens.length == 0) {
            revert("No tokens provided");
        }

        console.log("Deployer Address", deployer);
        console.log("Owner Address", owner);
        console.log("Verifying Signer Address", verifyingSigner);

        vm.startBroadcast(deployerPrivKey);

        InvoiceManager invoiceManager = InvoiceManager(
            payable(
                new UpgradeableOpenfortProxy{salt: versionSalt}(
                    address(new InvoiceManager()),
                    ""
                )
            )
        );
        console.log("InvoiceManager Address", address(invoiceManager));
        VaultManager vaultManager = VaultManager(
            payable(
                new UpgradeableOpenfortProxy{salt: versionSalt}(
                    address(new VaultManager()),
                    abi.encodeWithSelector(
                        VaultManager.initialize.selector,
                        owner,
                        IInvoiceManager(address(invoiceManager)),
                        withdrawLockBlock
                    )
                )
            )
        );

        invoiceManager.initialize(owner, IVaultManager(address(vaultManager)));

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];

            // Check if the token is deployed
            if (token.code.length == 0) {
                revert("Token not deployed");
            }

            // Deploy BaseVault for the token
            BaseVault baseVault = BaseVault(
                payable(
                    new UpgradeableOpenfortProxy{salt: versionSalt}(
                        address(new BaseVault()),
                        abi.encodeWithSelector(
                            BaseVault.initialize.selector,
                            IVaultManager(address(vaultManager)),
                            IERC20(token)
                        )
                    )
                )
            );
            console.log("BaseVault Address", address(baseVault));
            vaultManager.addVault(baseVault);

            // If the token is active in Aave, deploy AaveVault
            if (isAaveToken(protocolDataProvider, token)) {
                AaveVault aaveVault = AaveVault(
                    payable(
                        new UpgradeableOpenfortProxy{salt: versionSalt}(
                            address(new AaveVault()),
                            abi.encodeWithSelector(
                                AaveVault.initialize.selector,
                                IVaultManager(address(vaultManager)),
                                IERC20(token),
                                aavePool,
                                l2Encoder
                            )
                        )
                    )
                );
                console.log("AaveVault Address", address(aaveVault));
                vaultManager.addVault(aaveVault);
            }
        }

        IEntryPoint entryPoint = checkOrDeployEntryPoint();

        CABPaymaster paymaster = new CABPaymaster{salt: versionSalt}(
            entryPoint,
            IInvoiceManager(address(invoiceManager)),
            ICrossL2Prover(crossL2Prover),
            verifyingSigner,
            owner
        );

        console.log("Paymaster Address", address(paymaster));
        vm.stopBroadcast();
    }
}