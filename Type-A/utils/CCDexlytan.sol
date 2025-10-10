// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.0.1 (10/10/2025)
// Changes:
// - v0.0.1: Initial implementation with queryYield, queryDurationVolume, getMidnightIndicies, and queryPriceTrend.

interface IERC20 {
    function decimals() external view returns (uint8);
}

interface ICCLiquidityTemplate {
    function liquidityDetail() external view returns (
        uint256 xLiq,
        uint256 yLiq,
        uint256 xFees,
        uint256 yFees,
        uint256 xFeesAcc,
        uint256 yFeesAcc
    );
}

interface ICCListingTemplate {
    function prices(uint256 listingId) external view returns (uint256 price);
    function historicalDataLengthView() external view returns (uint256 length);
    function getHistoricalDataView(uint256 index) external view returns (
        uint256 price,
        uint256 xBalance,
        uint256 yBalance,
        uint256 xVolume,
        uint256 yVolume,
        uint256 timestamp
    );
    function liquidityAddressView() external view returns (address);
    function dayStartFee() external view  returns (
        uint256 dayStartXFeesAcc,
        uint256 dayStartYFeesAcc,
        uint256 timestamp); 
}

contract CCDexlytan {
    struct DayStartFee {
        uint256 dayStartXFeesAcc; // Tracks xFeesAcc at midnight
        uint256 dayStartYFeesAcc; // Tracks yFeesAcc at midnight
        uint256 timestamp; // Midnight timestamp
    }

    struct HistoricalData {
        uint256 price;
        uint256 xBalance;
        uint256 yBalance;
        uint256 xVolume;
        uint256 yVolume;
        uint256 timestamp;
    }

    // Calculates annualized yield, simulating user deposit
    function queryYield(address listingAddress, bool isTokenA, uint256 depositAmount) external view returns (uint256 yieldAnnualized) {
    address liquidityAddress;
    try ICCListingTemplate(listingAddress).liquidityAddressView() returns (address liqAddr) {
        liquidityAddress = liqAddr;
    } catch {
        return 0;
    }
    if (liquidityAddress == address(0) || depositAmount == 0) return 0;
    uint256 xLiquid;
    uint256 yLiquid;
    uint256 xFeesAcc;
    uint256 yFeesAcc;
    try ICCLiquidityTemplate(liquidityAddress).liquidityDetail() returns (
        uint256 xLiq,
        uint256 yLiq,
        uint256,
        uint256,
        uint256 xFees,
        uint256 yFees
    ) {
        xLiquid = xLiq;
        yLiquid = yLiq;
        xFeesAcc = xFees;
        yFeesAcc = yFees;
    } catch {
        return 0;
    }
    DayStartFee memory dayStart;
    try ICCListingTemplate(listingAddress).dayStartFee() returns (
        uint256 dayStartXFeesAcc,
        uint256 dayStartYFeesAcc,
        uint256 timestamp
    ) {
        dayStart = DayStartFee(dayStartXFeesAcc, dayStartYFeesAcc, timestamp);
    } catch {
        return 0;
    }
    if (dayStart.timestamp == 0) return 0;
    uint256 fees = isTokenA ? xFeesAcc : yFeesAcc;
    uint256 dFeesAcc = isTokenA ? dayStart.dayStartXFeesAcc : dayStart.dayStartYFeesAcc;
    uint256 liquid = isTokenA ? xLiquid : yLiquid;
    uint256 contributedFees = fees > dFeesAcc ? fees - dFeesAcc : 0;
    uint256 liquidityContribution = liquid > 0 ? (depositAmount * 1e18) / (liquid + depositAmount) : 0;
    uint256 feeShare = (contributedFees * liquidityContribution) / 1e18;
    feeShare = feeShare > contributedFees ? contributedFees : feeShare;
    uint256 dailyFees = feeShare;
    yieldAnnualized = (dailyFees * 365 * 10000) / (depositAmount > 0 ? depositAmount : 1);
    return yieldAnnualized;
}

    // Approximates volume over a specified number of days
    function queryDurationVolume(address listingAddress, bool isA, uint256 durationDays, uint256 maxIterations) external view returns (uint256 volume) {
        require(durationDays > 0, "Invalid durationDays");
        require(maxIterations > 0, "Invalid maxIterations");
        uint256 length;
        try ICCListingTemplate(listingAddress).historicalDataLengthView() returns (uint256 len) {
            length = len;
        } catch {
            return 0;
        }
        if (length == 0) return 0;
        uint256 currentMidnight = (block.timestamp / 86400) * 86400;
        uint256 startMidnight = currentMidnight - (durationDays * 86400);
        uint256 totalVolume = 0;
        uint256 iterationsLeft = maxIterations;
        for (uint256 i = length; i > 0 && iterationsLeft > 0; i--) {
            try ICCListingTemplate(listingAddress).getHistoricalDataView(i - 1) returns (
                uint256,
                uint256,
                uint256,
                uint256 xVol,
                uint256 yVol,
                uint256 timestamp
            ) {
                if (timestamp >= startMidnight && timestamp <= currentMidnight) {
                    totalVolume += isA ? xVol : yVol;
                }
            } catch {
                continue;
            }
            iterationsLeft--;
        }
        return totalVolume;
    }

    // Returns historical data indices at midnight from current day backwards
    function getMidnightIndicies(address listingAddress, uint256 count, uint256 maxIterations) external view returns (uint256[] memory indices, uint256[] memory timestamps) {
        require(maxIterations > 0, "Invalid maxIterations");
        uint256 currentMidnight = (block.timestamp / 86400) * 86400;
        uint256[] memory tempIndices = new uint256[](maxIterations);
        uint256[] memory tempTimestamps = new uint256[](maxIterations);
        uint256 found = 0;
        uint256 iterationsLeft = maxIterations;
        for (uint256 i = 0; i < count && iterationsLeft > 0; i++) {
            uint256 dayTimestamp = currentMidnight - (i * 86400);
            try ICCListingTemplate(listingAddress).getHistoricalDataView(i) returns (
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256 timestamp
            ) {
                if (timestamp == dayTimestamp) {
                    tempIndices[found] = i;
                    tempTimestamps[found] = dayTimestamp;
                    found++;
                }
            } catch {
                continue;
            }
            iterationsLeft--;
        }
        indices = new uint256[](found);
        timestamps = new uint256[](found);
        for (uint256 i = 0; i < found; i++) {
            indices[i] = tempIndices[i];
            timestamps[i] = tempTimestamps[i];
        }
    }

    // Analyzes price trend over a specified number of days
    function queryPriceTrend(address listingAddress, uint256 durationDays, uint256 maxIterations) external view returns (uint256[] memory prices, uint256[] memory timestamps) {
        require(durationDays > 0, "Invalid durationDays");
        require(maxIterations > 0, "Invalid maxIterations");
        uint256 length;
        try ICCListingTemplate(listingAddress).historicalDataLengthView() returns (uint256 len) {
            length = len;
        } catch {
            return (new uint256[](0), new uint256[](0));
        }
        if (length == 0) return (new uint256[](0), new uint256[](0));
        uint256 currentMidnight = (block.timestamp / 86400) * 86400;
        uint256 startMidnight = currentMidnight - (durationDays * 86400);
        uint256[] memory tempPrices = new uint256[](maxIterations);
        uint256[] memory tempTimestamps = new uint256[](maxIterations);
        uint256 found = 0;
        uint256 iterationsLeft = maxIterations;
        for (uint256 i = length; i > 0 && iterationsLeft > 0; i--) {
            try ICCListingTemplate(listingAddress).getHistoricalDataView(i - 1) returns (
                uint256 price,
                uint256,
                uint256,
                uint256,
                uint256,
                uint256 timestamp
            ) {
                if (timestamp >= startMidnight && timestamp <= currentMidnight) {
                    tempPrices[found] = price;
                    tempTimestamps[found] = timestamp;
                    found++;
                }
            } catch {
                continue;
            }
            iterationsLeft--;
        }
        prices = new uint256[](found);
        timestamps = new uint256[](found);
        for (uint256 i = 0; i < found; i++) {
            prices[i] = tempPrices[i];
            timestamps[i] = tempTimestamps[i];
        }
    }
}