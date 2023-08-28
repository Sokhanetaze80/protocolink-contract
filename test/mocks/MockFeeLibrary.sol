// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {IParam} from 'src/interfaces/IParam.sol';
import {FeeLibrary} from 'src/libraries/FeeLibrary.sol';

contract MockFeeLibrary {
    using FeeLibrary for IParam.Fee;

    function pay(IParam.Fee memory fee, address feeCollector) external {
        fee.pay(feeCollector);
    }

    /// @dev Notice that fee should not be NATIVE and should be verified before calling
    function payFrom(IParam.Fee memory fee, address from, address feeCollector, address permit2) external {
        fee.payFrom(from, feeCollector, permit2);
    }
}
