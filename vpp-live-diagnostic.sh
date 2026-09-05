#!/bin/bash

# ============================================================
# VPP Live Diagnostic v2.2
#
# VyOS / VPP / DPDK mlx5 / DET44
#
# Designed for:
#   - eth2 / eth3 physical DPDK interfaces
#   - BondEthernet0
#   - 6 RX queues per interface
#
# Monitoring:
#   - RX packets / real RX PPS
#   - rx_missed
#   - rx_out_of_buffer
#   - RX loss %
#   - rx_mbuf_allocation_errors
#   - rx_errors
#   - PHY CRC / PHY discard
#   - per-RX-queue PPS
#   - VPP worker runtime
#   - BondEthernet0-tx "no member"
#   - automatic event snapshots
#
# IMPORTANT:
#   Script does NOT change VPP configuration.
#
# Usage:
#
#   chmod +x /config/scripts/vpp-live-diagnostic.sh
#
#   sudo /config/scripts/vpp-live-diagnostic.sh
#
# or:
#
#   sudo /config/scripts/vpp-live-diagnostic.sh 1
#
# Argument:
#   polling interval in seconds
#
# Recommended:
#   1 second
#
# Ctrl+C to stop.
# ============================================================


set -u


# ============================================================
# Configuration
# ============================================================

INTERVAL="${1:-1}"

VPPCTL="${VPPCTL:-vppctl}"

IFACES=(
    "eth2"
    "eth3"
)

BOND_NAME="BondEthernet0"

RX_QUEUE_COUNT=6

BASE_DIR="/tmp/vpp-live-diagnostic"

EVENT_DIR="${BASE_DIR}/events"

METRICS_CSV="${BASE_DIR}/metrics.csv"
QUEUE_CSV="${BASE_DIR}/queues.csv"
RUNTIME_CSV="${BASE_DIR}/runtime.csv"
BOND_CSV="${BASE_DIR}/bond.csv"

# How often to execute "show runtime"
RUNTIME_INTERVAL=5

# How often to refresh "show errors"
ERRORS_INTERVAL=5

# Create RX event if missed/outbuf increased by at least this amount.
RX_TRIGGER_DELTA=1

# Create bond event if "no member" increased.
BOND_TRIGGER_DELTA=1

# Do not create full snapshots more often than this.
EVENT_COOLDOWN=10

# Number of recent CSV lines copied into event.
EVENT_METRICS_HISTORY=60
EVENT_QUEUE_HISTORY=360
EVENT_BOND_HISTORY=60
EVENT_RUNTIME_HISTORY=100


# ============================================================
# Headers
# ============================================================

EXPECTED_METRICS_HEADER="timestamp,interface,interval_sec,rx_packets,rx_delta,rx_pps,rx_missed,missed_delta,missed_pps,rx_out_of_buffer,outbuf_delta,outbuf_pps,loss_percent,rx_mbuf_errors,rx_errors,rx_phy_crc,rx_phy_discard"

EXPECTED_QUEUE_HEADER="timestamp,interface,queue,interval_sec,rx_packets,rx_delta,rx_pps"

EXPECTED_RUNTIME_HEADER="timestamp,worker,internal_vector_rate,loops_sec,in_rate,out_rate,drop_rate,punt_rate"

EXPECTED_BOND_HEADER="timestamp,interval_sec,bond_no_member,bond_no_member_delta,bond_no_member_rate"


# ============================================================
# Basic validation
# ============================================================

if ! [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: INTERVAL must be integer >= 1"
    exit 1
fi

if ! command -v "$VPPCTL" >/dev/null 2>&1; then
    echo "ERROR: vppctl not found"
    exit 1
fi


mkdir -p "$BASE_DIR"
mkdir -p "$EVENT_DIR"


# ============================================================
# Helpers
# ============================================================

timestamp()
{
    date '+%Y-%m-%d %H:%M:%S'
}


timestamp_file()
{
    date '+%Y%m%d-%H%M%S'
}


epoch_ns()
{
    date +%s%N
}


# ------------------------------------------------------------
# Central VPP wrapper.
#
# IMPORTANT:
# Some VPP outputs contain CR (\r).
#
# Without this:
#
#   29281090\r
#
# fails numeric validation and all deltas become zero.
# ------------------------------------------------------------

vpp()
{
    "$VPPCTL" "$@" 2>/dev/null | tr -d '\r'
}


is_uint()
{
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}


normalize_uint()
{
    local value="${1:-0}"

    value="${value//,/}"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '0'
    fi
}


delta_counter()
{
    local current
    local previous

    current="$(normalize_uint "${1:-0}")"
    previous="$(normalize_uint "${2:-0}")"

    if (( current >= previous )); then
        echo $((current - previous))
    else
        # Counter reset / VPP restart.
        echo 0
    fi
}


rate_counter()
{
    local delta="${1:-0}"
    local seconds="${2:-1}"

    awk \
        -v d="$delta" \
        -v s="$seconds" \
        '
        BEGIN {
            if (s > 0)
                printf "%.2f", d / s
            else
                printf "0.00"
        }
        '
}


loss_percent()
{
    local received="${1:-0}"
    local missed="${2:-0}"

    awk \
        -v rx="$received" \
        -v miss="$missed" \
        '
        BEGIN {
            total = rx + miss

            if (total > 0)
                printf "%.4f", (miss / total) * 100
            else
                printf "0.0000"
        }
        '
}


format_seconds_from_ns()
{
    local ns="${1:-0}"

    awk \
        -v n="$ns" \
        '
        BEGIN {
            printf "%.6f", n / 1000000000
        }
        '
}


rotate_incompatible_csv()
{
    local file="$1"
    local expected="$2"

    if [[ -f "$file" ]]; then

        local current

        current="$(
            head -n1 "$file" 2>/dev/null |
            tr -d '\r'
        )"

        if [[ "$current" != "$expected" ]]; then

            local backup

            backup="${file}.old.$(timestamp_file)"

            mv "$file" "$backup"

            echo "INFO: rotated incompatible file:"
            echo "      $file"
            echo "   -> $backup"
            echo
        fi
    fi

    if [[ ! -f "$file" ]]; then
        printf '%s\n' "$expected" > "$file"
    fi
}


# ============================================================
# CSV preparation
# ============================================================

rotate_incompatible_csv \
    "$METRICS_CSV" \
    "$EXPECTED_METRICS_HEADER"

rotate_incompatible_csv \
    "$QUEUE_CSV" \
    "$EXPECTED_QUEUE_HEADER"

rotate_incompatible_csv \
    "$RUNTIME_CSV" \
    "$EXPECTED_RUNTIME_HEADER"

rotate_incompatible_csv \
    "$BOND_CSV" \
    "$EXPECTED_BOND_HEADER"


# ============================================================
# Hardware parser
#
# We call "show hardware-interfaces detail" once per interface
# and parse everything from the same output.
# ============================================================

parse_hardware()
{
    awk '
    /^[[:space:]]*rx frames ok[[:space:]]+/ {
        print "rx_packets=" $4
        next
    }

    /^[[:space:]]*rx missed[[:space:]]+/ {
        print "rx_missed=" $3
        next
    }

    /^[[:space:]]*rx_out_of_buffer[[:space:]]+/ {
        print "rx_outbuf=" $2
        next
    }

    /^[[:space:]]*rx_mbuf_allocation_errors[[:space:]]+/ {
        print "rx_mbuf=" $2
        next
    }

    /^[[:space:]]*rx_errors[[:space:]]+/ {
        print "rx_errors=" $2
        next
    }

    /^[[:space:]]*rx_phy_crc_errors[[:space:]]+/ {
        print "rx_crc=" $2
        next
    }

    /^[[:space:]]*rx_phy_discard_packets[[:space:]]+/ {
        print "rx_phy_discard=" $2
        next
    }

    $1 ~ /^rx_q[0-9]+_packets$/ {

        key=$1

        sub(/^rx_q/, "", key)
        sub(/_packets$/, "", key)

        print "q" key "=" $2
        next
    }
    '
}


# ============================================================
# Runtime parser
#
# Expected vector line:
#
# vector rates in 6.7868e4, out 1.3539e5,
# drop 4.6503e2, punt 1.9971e-1
#
# Correct fields:
#
# in   = $4
# out  = $6
# drop = $8
# punt = $10
# ============================================================

parse_runtime_csv()
{
    local ts="$1"

    awk \
        -v ts="$ts" \
        '
        /^Thread [0-9]+ vpp_wk_[0-9]+/ {

            worker=$3

            ivr=""
            loops=""

            next
        }


        worker != "" && /^Time / {

            for (i=1; i<=NF; i++) {

                if ($i == "rate") {

                    ivr=$(i+1)
                    gsub(/,/, "", ivr)

                }

                if ($i == "loops/sec") {

                    loops=$(i+1)
                    gsub(/,/, "", loops)

                }
            }

            next
        }


        worker != "" &&
        /^[[:space:]]*vector rates in / {

            inrate=$4
            outrate=$6
            droprate=$8
            puntrate=$10

            gsub(/,/, "", inrate)
            gsub(/,/, "", outrate)
            gsub(/,/, "", droprate)
            gsub(/,/, "", puntrate)

            printf "%s,%s,%s,%s,%s,%s,%s,%s\n",
                   ts,
                   worker,
                   ivr,
                   loops,
                   inrate,
                   outrate,
                   droprate,
                   puntrate

            worker=""
        }
        '
}


show_runtime_summary()
{
    awk '
        /^Thread [0-9]+ vpp_wk_[0-9]+/ {

            worker=$3
            ivr=""
            loops=""

            next
        }


        worker != "" && /^Time / {

            for (i=1; i<=NF; i++) {

                if ($i == "rate") {

                    ivr=$(i+1)
                    gsub(/,/, "", ivr)

                }

                if ($i == "loops/sec") {

                    loops=$(i+1)
                    gsub(/,/, "", loops)

                }
            }

            next
        }


        worker != "" &&
        /^[[:space:]]*vector rates in / {

            inrate=$4
            outrate=$6
            droprate=$8
            puntrate=$10

            gsub(/,/, "", inrate)
            gsub(/,/, "", outrate)
            gsub(/,/, "", droprate)
            gsub(/,/, "", puntrate)

            printf "%-9s ivr=%7s loops=%12s in=%10s out=%10s drop=%9s punt=%9s\n",
                   worker,
                   ivr,
                   loops,
                   inrate,
                   outrate,
                   droprate,
                   puntrate

            worker=""
        }
        '
}


# ============================================================
# Bond "no member" parser
#
# Sum all matching counters because "show errors" can contain
# one counter per worker/thread.
# ============================================================

get_bond_no_member()
{
    awk \
        -v bond="$BOND_NAME" \
        '
        index($0, bond "-tx") &&
        index($0, "no member") {

            value=$1
            gsub(/,/, "", value)

            if (value ~ /^[0-9]+$/)
                total += value
        }

        END {
            printf "%.0f\n", total
        }
        '
}


# ============================================================
# State
# ============================================================

declare -A PREV_RX
declare -A PREV_MISSED
declare -A PREV_OUTBUF
declare -A PREV_QUEUE

declare -A SCREEN_RX_PPS
declare -A SCREEN_MISSED_DELTA
declare -A SCREEN_MISSED_PPS
declare -A SCREEN_MISSED_TOTAL
declare -A SCREEN_OUTBUF_DELTA
declare -A SCREEN_OUTBUF_PPS
declare -A SCREEN_OUTBUF_TOTAL
declare -A SCREEN_LOSS
declare -A SCREEN_MBUF
declare -A SCREEN_RX_ERRORS
declare -A SCREEN_CRC
declare -A SCREEN_PHY_DISCARD
declare -A SCREEN_Q_PPS

LAST_RUNTIME_RAW=""
LAST_RUNTIME_EPOCH=0

LAST_ERRORS_RAW=""
LAST_ERRORS_EPOCH=0

PREV_BOND_NO_MEMBER=0
CURRENT_BOND_NO_MEMBER=0
CURRENT_BOND_DELTA=0
CURRENT_BOND_RATE="0.00"

LAST_EVENT_EPOCH=0


# ============================================================
# Event snapshot
# ============================================================

create_snapshot()
{
    local reason="$1"
    local dt="$2"

    local now_epoch
    local event_stamp
    local dir

    now_epoch="$(date +%s)"

    if (( now_epoch - LAST_EVENT_EPOCH < EVENT_COOLDOWN )); then
        return
    fi

    LAST_EVENT_EPOCH="$now_epoch"

    event_stamp="$(timestamp_file)"
    dir="${EVENT_DIR}/${event_stamp}"

    mkdir -p "$dir"


    # --------------------------------------------------------
    # Metadata
    # --------------------------------------------------------

    {
        echo "Timestamp: $(timestamp)"
        echo "Epoch: $now_epoch"
        echo "Measured interval: $dt sec"
        echo "Reason: $reason"
        echo

        echo "INTERVAL=$INTERVAL"
        echo "RUNTIME_INTERVAL=$RUNTIME_INTERVAL"
        echo "ERRORS_INTERVAL=$ERRORS_INTERVAL"
        echo "RX_TRIGGER_DELTA=$RX_TRIGGER_DELTA"
        echo "BOND_TRIGGER_DELTA=$BOND_TRIGGER_DELTA"
        echo "EVENT_COOLDOWN=$EVENT_COOLDOWN"

    } > "${dir}/event.txt"


    # --------------------------------------------------------
    # Recent history
    # --------------------------------------------------------

    if [[ -f "$METRICS_CSV" ]]; then
        {
            head -n1 "$METRICS_CSV"
            tail -n "$EVENT_METRICS_HISTORY" "$METRICS_CSV"
        } > "${dir}/metrics-history.csv"
    fi


    if [[ -f "$QUEUE_CSV" ]]; then
        {
            head -n1 "$QUEUE_CSV"
            tail -n "$EVENT_QUEUE_HISTORY" "$QUEUE_CSV"
        } > "${dir}/queues-history.csv"
    fi


    if [[ -f "$BOND_CSV" ]]; then
        {
            head -n1 "$BOND_CSV"
            tail -n "$EVENT_BOND_HISTORY" "$BOND_CSV"
        } > "${dir}/bond-history.csv"
    fi


    if [[ -f "$RUNTIME_CSV" ]]; then
        {
            head -n1 "$RUNTIME_CSV"
            tail -n "$EVENT_RUNTIME_HISTORY" "$RUNTIME_CSV"
        } > "${dir}/runtime-history.csv"
    fi


    # --------------------------------------------------------
    # Cached BEFORE state
    # --------------------------------------------------------

    if [[ -n "$LAST_ERRORS_RAW" ]]; then

        printf '%s\n' "$LAST_ERRORS_RAW" \
            > "${dir}/errors-before.txt"

    fi


    if [[ -n "$LAST_RUNTIME_RAW" ]]; then

        printf '%s\n' "$LAST_RUNTIME_RAW" \
            > "${dir}/runtime-before.txt"

    fi


    # --------------------------------------------------------
    # Current VPP state
    # --------------------------------------------------------

    vpp show hardware-interfaces detail \
        > "${dir}/hardware-interfaces.txt"


    vpp show interface \
        > "${dir}/interfaces.txt"


    vpp show interface rx-placement \
        > "${dir}/rx-placement.txt"


    vpp show runtime \
        > "${dir}/runtime-event.txt"


    vpp show errors \
        > "${dir}/errors-event.txt"


    vpp show buffers \
        > "${dir}/buffers.txt"


    vpp show det44 mappings \
        > "${dir}/det44-mappings.txt"


    # --------------------------------------------------------
    # Intentionally NOT executing:
    #
    #   show det44 sessions
    #
    # This can produce huge output on a production CGNAT.
    # --------------------------------------------------------


    # --------------------------------------------------------
    # OS information
    #
    # OS CPU percentages are only supplementary.
    # VPP workers are polling and commonly show ~100% CPU.
    # --------------------------------------------------------

    {
        echo "===== DATE ====="
        date

        echo
        echo "===== UPTIME ====="
        uptime

        echo
        echo "===== LOADAVG ====="
        cat /proc/loadavg

        echo
        echo "===== MEMINFO ====="
        cat /proc/meminfo

        echo
        echo "===== INTERRUPTS ====="
        cat /proc/interrupts

    } > "${dir}/system.txt" 2>&1


    if command -v mpstat >/dev/null 2>&1; then

        mpstat -P ALL 1 1 \
            > "${dir}/mpstat.txt" 2>&1

    fi


    if command -v ip >/dev/null 2>&1; then

        ip -s link \
            > "${dir}/ip-link.txt" 2>&1

    fi


    if command -v dmesg >/dev/null 2>&1; then

        dmesg |
        tail -n 400 \
            > "${dir}/dmesg-tail.txt" 2>&1

    fi


    if command -v logger >/dev/null 2>&1; then

        logger \
            -t vpp-live-diagnostic \
            "VPP event: ${reason}; snapshot=${dir}"

    fi


    echo
    echo "************************************************************"
    echo "*** VPP DIAGNOSTIC EVENT"
    echo "***"
    echo "*** $reason"
    echo "***"
    echo "*** snapshot:"
    echo "*** $dir"
    echo "************************************************************"
    echo
}


# ============================================================
# Ctrl+C handler
# ============================================================

cleanup()
{
    echo
    echo "============================================================"
    echo " VPP LIVE DIAGNOSTIC STOPPED"
    echo "============================================================"
    echo
    echo "Metrics : $METRICS_CSV"
    echo "Queues  : $QUEUE_CSV"
    echo "Runtime : $RUNTIME_CSV"
    echo "Bond    : $BOND_CSV"
    echo "Events  : $EVENT_DIR"
    echo

    exit 0
}


trap cleanup INT TERM


# ============================================================
# VPP availability
# ============================================================

if ! vpp show version >/dev/null 2>&1; then

    echo "ERROR: VPP is not available"
    exit 1

fi


# ============================================================
# Initial hardware counters
# ============================================================

echo "Reading initial VPP counters..."


for iface in "${IFACES[@]}"; do

    declare -A INIT=()

    DATA="$(vpp show hardware-interfaces detail "$iface")"

    if [[ -z "$DATA" ]]; then

        echo "ERROR: cannot read hardware stats for $iface"
        exit 1

    fi


    while IFS='=' read -r key value; do

        [[ -z "$key" ]] && continue

        INIT["$key"]="$(normalize_uint "$value")"

    done < <(
        printf '%s\n' "$DATA" |
        parse_hardware
    )


    PREV_RX["$iface"]="${INIT[rx_packets]:-0}"
    PREV_MISSED["$iface"]="${INIT[rx_missed]:-0}"
    PREV_OUTBUF["$iface"]="${INIT[rx_outbuf]:-0}"


    for ((q=0; q<RX_QUEUE_COUNT; q++)); do

        KEY="${iface}_${q}"

        PREV_QUEUE["$KEY"]="${INIT[q$q]:-0}"
        SCREEN_Q_PPS["$KEY"]="0.00"

    done


    unset INIT

done


# ============================================================
# Initial errors / bond counter
# ============================================================

LAST_ERRORS_RAW="$(vpp show errors)"

LAST_ERRORS_EPOCH="$(date +%s)"

PREV_BOND_NO_MEMBER="$(
    printf '%s\n' "$LAST_ERRORS_RAW" |
    get_bond_no_member
)"

PREV_BOND_NO_MEMBER="$(
    normalize_uint "$PREV_BOND_NO_MEMBER"
)"

CURRENT_BOND_NO_MEMBER="$PREV_BOND_NO_MEMBER"


# ============================================================
# Initial runtime
# ============================================================

LAST_RUNTIME_RAW="$(vpp show runtime)"
LAST_RUNTIME_EPOCH="$(date +%s)"

TS="$(timestamp)"

printf '%s\n' "$LAST_RUNTIME_RAW" |
parse_runtime_csv "$TS" \
    >> "$RUNTIME_CSV"


# ============================================================
# Startup info
# ============================================================

echo
echo "============================================================"
echo " VPP LIVE DIAGNOSTIC v2.2"
echo "============================================================"
echo
echo "Polling interval   : ${INTERVAL}s"
echo "Runtime interval   : ${RUNTIME_INTERVAL}s"
echo "Errors interval    : ${ERRORS_INTERVAL}s"
echo "RX trigger delta   : ${RX_TRIGGER_DELTA}"
echo "Bond trigger delta : ${BOND_TRIGGER_DELTA}"
echo "Event cooldown     : ${EVENT_COOLDOWN}s"
echo
echo "Metrics            : $METRICS_CSV"
echo "Queues             : $QUEUE_CSV"
echo "Runtime            : $RUNTIME_CSV"
echo "Bond               : $BOND_CSV"
echo "Events             : $EVENT_DIR"
echo
echo "Current RX placement:"
echo

vpp show interface rx-placement

echo
echo "============================================================"
echo


# ============================================================
# Baseline timing
# ============================================================

PREV_SAMPLE_NS="$(epoch_ns)"

sleep "$INTERVAL"


# ============================================================
# Main loop
# ============================================================

while true; do

    LOOP_START_NS="$(epoch_ns)"

    NOW_NS="$LOOP_START_NS"
    NOW_EPOCH="$(date +%s)"

    TS="$(timestamp)"


    # --------------------------------------------------------
    # Actual interval between samples
    # --------------------------------------------------------

    DT_NS=$((NOW_NS - PREV_SAMPLE_NS))

    if (( DT_NS <= 0 )); then
        DT_NS=$((INTERVAL * 1000000000))
    fi

    DT_SEC="$(format_seconds_from_ns "$DT_NS")"


    EVENT_REASON=""

    TOTAL_RX_DELTA=0
    TOTAL_MISSED_DELTA=0


    # ========================================================
    # Periodic runtime
    # ========================================================

    if (( NOW_EPOCH - LAST_RUNTIME_EPOCH >= RUNTIME_INTERVAL )); then

        LAST_RUNTIME_RAW="$(vpp show runtime)"
        LAST_RUNTIME_EPOCH="$NOW_EPOCH"


        printf '%s\n' "$LAST_RUNTIME_RAW" |
        parse_runtime_csv "$TS" \
            >> "$RUNTIME_CSV"

    fi


    # ========================================================
    # Physical interfaces
    # ========================================================

    for iface in "${IFACES[@]}"; do

        declare -A CUR=()


        # ----------------------------------------------------
        # One VPP hardware call per interface.
        # ----------------------------------------------------

        DATA="$(vpp show hardware-interfaces detail "$iface")"


        while IFS='=' read -r key value; do

            [[ -z "$key" ]] && continue

            CUR["$key"]="$(normalize_uint "$value")"

        done < <(
            printf '%s\n' "$DATA" |
            parse_hardware
        )


        RX="${CUR[rx_packets]:-0}"
        MISSED="${CUR[rx_missed]:-0}"
        OUTBUF="${CUR[rx_outbuf]:-0}"

        MBUF_ERR="${CUR[rx_mbuf]:-0}"
        RX_ERR="${CUR[rx_errors]:-0}"
        CRC="${CUR[rx_crc]:-0}"
        PHY_DISCARD="${CUR[rx_phy_discard]:-0}"


        # ----------------------------------------------------
        # Deltas
        # ----------------------------------------------------

        RX_DELTA="$(
            delta_counter \
                "$RX" \
                "${PREV_RX[$iface]:-0}"
        )"


        MISSED_DELTA="$(
            delta_counter \
                "$MISSED" \
                "${PREV_MISSED[$iface]:-0}"
        )"


        OUTBUF_DELTA="$(
            delta_counter \
                "$OUTBUF" \
                "${PREV_OUTBUF[$iface]:-0}"
        )"


        # ----------------------------------------------------
        # Actual PPS
        # ----------------------------------------------------

        RX_PPS="$(
            rate_counter \
                "$RX_DELTA" \
                "$DT_SEC"
        )"


        MISSED_PPS="$(
            rate_counter \
                "$MISSED_DELTA" \
                "$DT_SEC"
        )"


        OUTBUF_PPS="$(
            rate_counter \
                "$OUTBUF_DELTA" \
                "$DT_SEC"
        )"


        LOSS="$(
            loss_percent \
                "$RX_DELTA" \
                "$MISSED_DELTA"
        )"


        TOTAL_RX_DELTA=$((TOTAL_RX_DELTA + RX_DELTA))
        TOTAL_MISSED_DELTA=$((TOTAL_MISSED_DELTA + MISSED_DELTA))


        # ----------------------------------------------------
        # Screen values
        # ----------------------------------------------------

        SCREEN_RX_PPS["$iface"]="$RX_PPS"

        SCREEN_MISSED_DELTA["$iface"]="$MISSED_DELTA"
        SCREEN_MISSED_PPS["$iface"]="$MISSED_PPS"
        SCREEN_MISSED_TOTAL["$iface"]="$MISSED"

        SCREEN_OUTBUF_DELTA["$iface"]="$OUTBUF_DELTA"
        SCREEN_OUTBUF_PPS["$iface"]="$OUTBUF_PPS"
        SCREEN_OUTBUF_TOTAL["$iface"]="$OUTBUF"

        SCREEN_LOSS["$iface"]="$LOSS"

        SCREEN_MBUF["$iface"]="$MBUF_ERR"
        SCREEN_RX_ERRORS["$iface"]="$RX_ERR"
        SCREEN_CRC["$iface"]="$CRC"
        SCREEN_PHY_DISCARD["$iface"]="$PHY_DISCARD"


        # ----------------------------------------------------
        # metrics.csv
        # ----------------------------------------------------

        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$TS" \
            "$iface" \
            "$DT_SEC" \
            "$RX" \
            "$RX_DELTA" \
            "$RX_PPS" \
            "$MISSED" \
            "$MISSED_DELTA" \
            "$MISSED_PPS" \
            "$OUTBUF" \
            "$OUTBUF_DELTA" \
            "$OUTBUF_PPS" \
            "$LOSS" \
            "$MBUF_ERR" \
            "$RX_ERR" \
            "$CRC" \
            "$PHY_DISCARD" \
            >> "$METRICS_CSV"


        # ----------------------------------------------------
        # RX event reason
        #
        # Do not create duplicate messages for missed/outbuf.
        # Show both counters in one reason.
        # ----------------------------------------------------

        if (( MISSED_DELTA >= RX_TRIGGER_DELTA ||
              OUTBUF_DELTA >= RX_TRIGGER_DELTA )); then

            EVENT_REASON+="${iface}:missed+${MISSED_DELTA}/outbuf+${OUTBUF_DELTA}/loss=${LOSS}% "

        fi


        # ====================================================
        # RX queues
        # ====================================================

        for ((q=0; q<RX_QUEUE_COUNT; q++)); do

            KEY="${iface}_${q}"

            Q_CUR="${CUR[q$q]:-0}"


            Q_DELTA="$(
                delta_counter \
                    "$Q_CUR" \
                    "${PREV_QUEUE[$KEY]:-0}"
            )"


            Q_PPS="$(
                rate_counter \
                    "$Q_DELTA" \
                    "$DT_SEC"
            )"


            SCREEN_Q_PPS["$KEY"]="$Q_PPS"


            printf '%s,%s,%s,%s,%s,%s,%s\n' \
                "$TS" \
                "$iface" \
                "$q" \
                "$DT_SEC" \
                "$Q_CUR" \
                "$Q_DELTA" \
                "$Q_PPS" \
                >> "$QUEUE_CSV"


            PREV_QUEUE["$KEY"]="$Q_CUR"

        done


        PREV_RX["$iface"]="$RX"
        PREV_MISSED["$iface"]="$MISSED"
        PREV_OUTBUF["$iface"]="$OUTBUF"


        unset CUR

    done


    # ========================================================
    # Bond error monitoring
    #
    # show errors is intentionally not executed every second.
    # ========================================================

    CURRENT_BOND_DELTA=0
    CURRENT_BOND_RATE="0.00"


    if (( NOW_EPOCH - LAST_ERRORS_EPOCH >= ERRORS_INTERVAL )); then

        NEW_ERRORS_RAW="$(vpp show errors)"


        CURRENT_BOND_NO_MEMBER="$(
            printf '%s\n' "$NEW_ERRORS_RAW" |
            get_bond_no_member
        )"

        CURRENT_BOND_NO_MEMBER="$(
            normalize_uint "$CURRENT_BOND_NO_MEMBER"
        )"


        CURRENT_BOND_DELTA="$(
            delta_counter \
                "$CURRENT_BOND_NO_MEMBER" \
                "$PREV_BOND_NO_MEMBER"
        )"


        ERROR_DT=$((NOW_EPOCH - LAST_ERRORS_EPOCH))

        if (( ERROR_DT <= 0 )); then
            ERROR_DT="$ERRORS_INTERVAL"
        fi


        CURRENT_BOND_RATE="$(
            rate_counter \
                "$CURRENT_BOND_DELTA" \
                "$ERROR_DT"
        )"


        printf '%s,%s,%s,%s,%s\n' \
            "$TS" \
            "$ERROR_DT" \
            "$CURRENT_BOND_NO_MEMBER" \
            "$CURRENT_BOND_DELTA" \
            "$CURRENT_BOND_RATE" \
            >> "$BOND_CSV"


        if (( CURRENT_BOND_DELTA >= BOND_TRIGGER_DELTA )); then

            EVENT_REASON+="${BOND_NAME}-tx:no-member+${CURRENT_BOND_DELTA} "

        fi


        # Important:
        #
        # Keep previous errors for event "before" snapshot.
        #
        # First save the NEW data only after calculations.
        LAST_ERRORS_RAW="$NEW_ERRORS_RAW"
        LAST_ERRORS_EPOCH="$NOW_EPOCH"

        PREV_BOND_NO_MEMBER="$CURRENT_BOND_NO_MEMBER"

    fi


    # ========================================================
    # Aggregate loss
    # ========================================================

    TOTAL_LOSS="$(
        loss_percent \
            "$TOTAL_RX_DELTA" \
            "$TOTAL_MISSED_DELTA"
    )"


    TOTAL_RX_PPS="$(
        rate_counter \
            "$TOTAL_RX_DELTA" \
            "$DT_SEC"
    )"


    TOTAL_MISSED_PPS="$(
        rate_counter \
            "$TOTAL_MISSED_DELTA" \
            "$DT_SEC"
    )"


    # ========================================================
    # Screen
    # ========================================================

    [[ -t 1 ]] && clear


    echo "============================================================"
    echo " VPP LIVE DIAGNOSTIC v2.2"
    echo " $TS"
    echo " interval=${DT_SEC}s"
    echo "============================================================"


    echo
    echo "--- PHYSICAL RX ---------------------------------------------"
    echo


    printf "%-5s %11s %9s %9s %9s %10s %12s\n" \
        "IF" \
        "RX PPS" \
        "MISS/s" \
        "MISS+" \
        "LOSS%" \
        "NOBUF/s" \
        "NOBUF TOTAL"


    printf "%-5s %11s %9s %9s %9s %10s %12s\n" \
        "-----" \
        "-----------" \
        "---------" \
        "---------" \
        "---------" \
        "----------" \
        "------------"


    for iface in "${IFACES[@]}"; do

        printf "%-5s %11.0f %9.0f %9s %8s%% %10.0f %12s\n" \
            "$iface" \
            "${SCREEN_RX_PPS[$iface]:-0}" \
            "${SCREEN_MISSED_PPS[$iface]:-0}" \
            "${SCREEN_MISSED_DELTA[$iface]:-0}" \
            "${SCREEN_LOSS[$iface]:-0}" \
            "${SCREEN_OUTBUF_PPS[$iface]:-0}" \
            "${SCREEN_OUTBUF_TOTAL[$iface]:-0}"

    done


    echo
    printf "%-5s %11.0f %9.0f %9s %8s%%\n" \
        "TOTAL" \
        "$TOTAL_RX_PPS" \
        "$TOTAL_MISSED_PPS" \
        "$TOTAL_MISSED_DELTA" \
        "$TOTAL_LOSS"


    # ========================================================
    # RX queues
    # ========================================================

    echo
    echo "--- RX QUEUES PPS -------------------------------------------"
    echo


    printf "%-5s" "IF"

    for ((q=0; q<RX_QUEUE_COUNT; q++)); do
        printf " %10s" "Q$q"
    done

    echo


    printf "%-5s" "-----"

    for ((q=0; q<RX_QUEUE_COUNT; q++)); do
        printf " %10s" "----------"
    done

    echo


    for iface in "${IFACES[@]}"; do

        printf "%-5s" "$iface"

        for ((q=0; q<RX_QUEUE_COUNT; q++)); do

            KEY="${iface}_${q}"

            printf " %10.0f" \
                "${SCREEN_Q_PPS[$KEY]:-0}"

        done

        echo

    done


    # ========================================================
    # Hardware errors
    # ========================================================

    echo
    echo "--- HARDWARE ERRORS -----------------------------------------"
    echo


    printf "%-5s %12s %12s %12s %12s\n" \
        "IF" \
        "MBUF-ERR" \
        "RX-ERR" \
        "CRC" \
        "PHY-DISC"


    for iface in "${IFACES[@]}"; do

        printf "%-5s %12s %12s %12s %12s\n" \
            "$iface" \
            "${SCREEN_MBUF[$iface]:-0}" \
            "${SCREEN_RX_ERRORS[$iface]:-0}" \
            "${SCREEN_CRC[$iface]:-0}" \
            "${SCREEN_PHY_DISCARD[$iface]:-0}"

    done


    # ========================================================
    # Bond
    # ========================================================

    echo
    echo "--- BOND ----------------------------------------------------"
    echo

    printf "%-24s total=%-12s delta=%-8s rate=%s/s\n" \
        "${BOND_NAME}-tx no-member" \
        "$CURRENT_BOND_NO_MEMBER" \
        "$CURRENT_BOND_DELTA" \
        "$CURRENT_BOND_RATE"


    # ========================================================
    # Runtime
    # ========================================================

    echo
    echo "--- VPP WORKERS / RUNTIME ----------------------------------"
    echo


    if [[ -n "$LAST_RUNTIME_RAW" ]]; then

        printf '%s\n' "$LAST_RUNTIME_RAW" |
        show_runtime_summary

    else

        echo "runtime unavailable"

    fi


    # ========================================================
    # Event snapshot
    # ========================================================

    if [[ -n "$EVENT_REASON" ]]; then

        create_snapshot \
            "$EVENT_REASON" \
            "$DT_SEC"

    fi


    # ========================================================
    # Paths
    # ========================================================

    echo
    echo "--- FILES ---------------------------------------------------"
    echo

    echo "Metrics : $METRICS_CSV"
    echo "Queues  : $QUEUE_CSV"
    echo "Runtime : $RUNTIME_CSV"
    echo "Bond    : $BOND_CSV"
    echo "Events  : $EVENT_DIR"


    # ========================================================
    # Timing
    #
    # Sampling time is based on actual elapsed time.
    #
    # If event snapshot takes several seconds, the next sample
    # will correctly use that actual interval instead of
    # pretending that exactly 1 second elapsed.
    # ========================================================

    PREV_SAMPLE_NS="$NOW_NS"

    LOOP_END_NS="$(epoch_ns)"

    PROCESSING_NS=$((LOOP_END_NS - LOOP_START_NS))

    TARGET_NS=$((INTERVAL * 1000000000))


    if (( PROCESSING_NS < TARGET_NS )); then

        REMAIN_NS=$((TARGET_NS - PROCESSING_NS))

        REMAIN_SEC="$(
            format_seconds_from_ns "$REMAIN_NS"
        )"

        sleep "$REMAIN_SEC"

    fi

done
