// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable no-unused-import */
import { Execution, IERC7579Account } from "./external/ERC7579.sol";

import { AccountFactory as SafeFactory } from "./accounts/safe/src/Account.sol";
import "forge-std/Test.sol";

contract MultiAccount is Test {
    SafeFactory safeFactory;

    address defaultValidator;
    address defaultExecutor;

    Account signer1;
    Account signer2;
    uint256 threshold;

    constructor(address _defaultValidator, address _defaultExecutor) {
        safeFactory = new SafeFactory();

        signer1 = makeAccount("signer1");
        signer2 = makeAccount("signer2");

        defaultValidator = _defaultValidator;
        defaultExecutor = _defaultExecutor;
        threshold = 2;
    }

    function makeSafe() public returns (address account) {
        address[] memory signers = new address[](2);
        signers[0] = signer1.addr;
        signers[1] = signer2.addr;
        return safeFactory.safeSetup(signers, threshold, defaultValidator, defaultExecutor);
    }
}
