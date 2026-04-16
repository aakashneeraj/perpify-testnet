// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PerpifyReopen
 * @notice Perpify Continuity Engine — Gap-Aware Margining + Sequenced Reopen
 * @dev Deployed on Base Sepolia. Demonstrates the reopen gap solution.
 */
contract PerpifyReopen {

    // ─── CONSTANTS ────────────────────────────────────────────────────────────
    uint256 public constant SHIELD_BPS   = 500;   // 5% of OI as insurance shield
    uint256 public constant BASE_IMR_BPS = 1000;  // 10% base initial margin
    uint256 public constant GAP_IMR_BPS  = 1300;  // 13% gap-aware margin (1.3× tightening)
    uint256 public constant MAX_LEVERAGE = 6;
    uint256 public constant BPS          = 10000;

    // ─── RISK TIERS ───────────────────────────────────────────────────────────
    enum RiskTier { LOW, MEDIUM, HIGH }
    enum MarketState { OPEN, DARK, REOPEN }

    // ─── POSITION ─────────────────────────────────────────────────────────────
    struct Position {
        address trader;
        uint256 notional;    // position size in USDC (6 decimals)
        uint256 margin;      // collateral posted
        uint256 leverage;    // 1–6
        bool    isLong;
        bool    isOpen;
        RiskTier riskTier;
        uint256 gapAwareMargin; // margin required after gap-aware tightening
    }

    // ─── STATE ────────────────────────────────────────────────────────────────
    address public owner;
    MarketState public marketState;

    uint256 public totalOI;
    uint256 public shieldFund;
    uint256 public badDebt;
    uint256 public positionCount;

    mapping(uint256 => Position) public positions;
    uint256[] public openPositionIds;

    // ─── EVENTS ───────────────────────────────────────────────────────────────
    event PositionOpened(
        uint256 indexed posId,
        address indexed trader,
        uint256 notional,
        uint256 margin,
        uint256 leverage,
        bool isLong,
        RiskTier riskTier
    );

    event MarketClosed(
        uint256 totalOI,
        uint256 shieldFund,
        uint256 timestamp
    );

    event GapAwareMarginApplied(
        uint256 indexed posId,
        uint256 oldMargin,
        uint256 newMarginRequired,
        RiskTier riskTier
    );

    event ReopenInitiated(
        int256 gapBps,          // gap in basis points (negative = down gap)
        uint256 reopenPrice,
        uint256 timestamp
    );

    event PositionSequenced(
        uint256 indexed posId,
        RiskTier riskTier,
        uint256 loss,
        bool coveredByMargin,
        uint256 shieldUsed
    );

    event PositionCleared(
        uint256 indexed posId,
        address indexed trader,
        uint256 payout,
        uint256 badDebtGenerated
    );

    event ReopenComplete(
        uint256 totalPositionsCleared,
        uint256 totalBadDebt,
        uint256 shieldUsed,
        uint256 shieldUsedBps,   // shield used as % of shield fund in BPS
        bool protocolSolvent
    );

    // ─── MODIFIERS ────────────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier inState(MarketState s) {
        require(marketState == s, "Wrong market state");
        _;
    }

    // ─── CONSTRUCTOR ──────────────────────────────────────────────────────────
    constructor() {
        owner = msg.sender;
        marketState = MarketState.OPEN;
    }

    // ─── DEPOSIT & FUND ───────────────────────────────────────────────────────

    /**
     * @notice Fund the insurance shield
     */
    function fundShield() external payable {
        shieldFund += msg.value;
    }

    // ─── OPEN POSITION ────────────────────────────────────────────────────────

    /**
     * @notice Open a perpetual position. Margin posted as ETH (simulating USDC).
     * @param notionalUSD  Notional size in USD (scaled ×1e6)
     * @param leverage     1–6x
     * @param isLong       Direction
     * @param riskTier     Behavioral underwriting score (0=LOW,1=MED,2=HIGH)
     */
    function openPosition(
        uint256 notionalUSD,
        uint256 leverage,
        bool    isLong,
        RiskTier riskTier
    ) external payable inState(MarketState.OPEN) returns (uint256 posId) {
        require(leverage >= 1 && leverage <= MAX_LEVERAGE, "Bad leverage");
        require(notionalUSD > 0, "Zero notional");

        uint256 requiredMarginBps = _marginBps(riskTier, false);
        uint256 requiredMargin    = (notionalUSD * requiredMarginBps) / BPS;
        require(msg.value >= requiredMargin, "Insufficient margin");

        posId = positionCount++;
        positions[posId] = Position({
            trader:         msg.sender,
            notional:       notionalUSD,
            margin:         msg.value,
            leverage:       leverage,
            isLong:         isLong,
            isOpen:         true,
            riskTier:       riskTier,
            gapAwareMargin: 0
        });

        openPositionIds.push(posId);
        totalOI += notionalUSD;

        // Seed shield fund: 5% of each position's notional goes to shield
        uint256 shieldContrib = (notionalUSD * SHIELD_BPS) / BPS;
        shieldFund += shieldContrib;

        emit PositionOpened(posId, msg.sender, notionalUSD, msg.value, leverage, isLong, riskTier);
    }

    // ─── CLOSE MARKET ─────────────────────────────────────────────────────────

    /**
     * @notice Owner closes market (Friday 16:00). Activates gap-aware margining.
     * @dev In production this is triggered by the off-chain Continuity Engine.
     */
    function closeMarket() external onlyOwner inState(MarketState.OPEN) {
        marketState = MarketState.DARK;

        // Apply gap-aware margin tightening to all HIGH and MEDIUM risk positions
        for (uint256 i = 0; i < openPositionIds.length; i++) {
            uint256 pid = openPositionIds[i];
            Position storage pos = positions[pid];
            if (!pos.isOpen) continue;

            if (pos.riskTier == RiskTier.HIGH || pos.riskTier == RiskTier.MEDIUM) {
                uint256 newRequired = (pos.notional * GAP_IMR_BPS) / BPS;
                pos.gapAwareMargin  = newRequired;

                emit GapAwareMarginApplied(pid, pos.margin, newRequired, pos.riskTier);
            }
        }

        emit MarketClosed(totalOI, shieldFund, block.timestamp);
    }

    // ─── TRIGGER REOPEN ───────────────────────────────────────────────────────

    /**
     * @notice Trigger reopen with a gap. Runs SEQUENCED clearing — not a snap.
     * @param gapBps  Gap in basis points. Negative = down gap (e.g. −320 = −3.2%)
     * @param basePrice Pre-gap price scaled ×1e6
     *
     * Sequence: HIGH risk first → MEDIUM → LOW
     * This is the core Perpify mechanic. Naive venues do all simultaneously.
     */
    function triggerReopen(
        int256  gapBps,
        uint256 basePrice
    ) external onlyOwner inState(MarketState.DARK) {
        marketState = MarketState.REOPEN;

        // Compute reopen price
        uint256 reopenPrice;
        if (gapBps < 0) {
            uint256 drop = (basePrice * uint256(-gapBps)) / BPS;
            reopenPrice  = basePrice > drop ? basePrice - drop : 0;
        } else {
            reopenPrice  = basePrice + (basePrice * uint256(gapBps)) / BPS;
        }

        emit ReopenInitiated(gapBps, reopenPrice, block.timestamp);

        uint256 clearedCount = 0;

        // ── PASS 1: HIGH risk ──────────────────────────────────────────────
        for (uint256 i = 0; i < openPositionIds.length; i++) {
            uint256 pid = openPositionIds[i];
            if (positions[pid].isOpen && positions[pid].riskTier == RiskTier.HIGH) {
                _clearPosition(pid, gapBps, reopenPrice);
                clearedCount++;
            }
        }

        // ── PASS 2: MEDIUM risk ────────────────────────────────────────────
        for (uint256 i = 0; i < openPositionIds.length; i++) {
            uint256 pid = openPositionIds[i];
            if (positions[pid].isOpen && positions[pid].riskTier == RiskTier.MEDIUM) {
                _clearPosition(pid, gapBps, reopenPrice);
                clearedCount++;
            }
        }

        // ── PASS 3: LOW risk ───────────────────────────────────────────────
        for (uint256 i = 0; i < openPositionIds.length; i++) {
            uint256 pid = openPositionIds[i];
            if (positions[pid].isOpen && positions[pid].riskTier == RiskTier.LOW) {
                _clearPosition(pid, gapBps, reopenPrice);
                clearedCount++;
            }
        }

        // Compute shield usage
        uint256 shieldUsed     = badDebt;
        uint256 shieldInitial  = (totalOI * SHIELD_BPS) / BPS;
        uint256 shieldUsedBps  = shieldInitial > 0
            ? (shieldUsed * BPS) / shieldInitial
            : 0;
        bool    solvent        = shieldUsed <= shieldFund;

        emit ReopenComplete(
            clearedCount,
            badDebt,
            shieldUsed,
            shieldUsedBps,
            solvent
        );

        marketState = MarketState.OPEN;
    }

    // ─── INTERNAL: CLEAR POSITION ─────────────────────────────────────────────

    function _clearPosition(
        uint256 pid,
        int256  gapBps,
        uint256 reopenPrice
    ) internal {
        Position storage pos = positions[pid];
        if (!pos.isOpen) return;

        pos.isOpen = false;

        // P&L: long positions lose on down gap, short positions gain
        uint256 loss = 0;
        uint256 payout = 0;

        if (gapBps < 0 && pos.isLong) {
            // Down gap, long position — loss = notional × |gap|
            loss = (pos.notional * uint256(-gapBps)) / BPS;
        } else if (gapBps > 0 && !pos.isLong) {
            // Up gap, short position — loss
            loss = (pos.notional * uint256(gapBps)) / BPS;
        }

        uint256 shieldUsed = 0;
        uint256 positionBadDebt = 0;

        if (loss > 0) {
            if (pos.margin >= loss) {
                // Margin absorbs the loss — no bad debt
                payout = pos.margin - loss;
            } else {
                // Margin exhausted — draw from shield
                uint256 uncovered = loss - pos.margin;
                payout = 0;

                if (shieldFund >= uncovered) {
                    shieldFund   -= uncovered;
                    shieldUsed    = uncovered;
                } else {
                    // Shield exhausted — bad debt
                    positionBadDebt = uncovered - shieldFund;
                    shieldUsed      = shieldFund;
                    shieldFund      = 0;
                    badDebt        += positionBadDebt;
                }
            }
        } else {
            // No loss — return full margin
            payout = pos.margin;
        }

        emit PositionSequenced(pid, pos.riskTier, loss, loss <= pos.margin, shieldUsed);
        emit PositionCleared(pid, pos.trader, payout, positionBadDebt);

        // Return payout to trader
        if (payout > 0) {
            (bool ok,) = pos.trader.call{value: payout}("");
            require(ok, "Transfer failed");
        }
    }

    // ─── INTERNAL: MARGIN BPS ────────────────────────────────────────────────

    function _marginBps(RiskTier tier, bool gapAware) internal pure returns (uint256) {
        if (!gapAware) return BASE_IMR_BPS;
        if (tier == RiskTier.HIGH)   return GAP_IMR_BPS;
        if (tier == RiskTier.MEDIUM) return (GAP_IMR_BPS + BASE_IMR_BPS) / 2;
        return BASE_IMR_BPS;
    }

    // ─── VIEW ────────────────────────────────────────────────────────────────

    function getPosition(uint256 pid) external view returns (Position memory) {
        return positions[pid];
    }

    function getOpenPositionCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < openPositionIds.length; i++) {
            if (positions[openPositionIds[i]].isOpen) count++;
        }
    }

    function getShieldStatus() external view returns (
        uint256 fund,
        uint256 debt,
        uint256 usedBps
    ) {
        fund = shieldFund;
        debt = badDebt;
        uint256 shieldInitial = (totalOI * SHIELD_BPS) / BPS;
        usedBps = shieldInitial > 0 ? (debt * BPS) / shieldInitial : 0;
    }

    // ─── RESCUE ──────────────────────────────────────────────────────────────
    receive() external payable {}
}
