#!/bin/bash

###############################################################################
# VPP / VyOS CGNAT Prometheus exporter
#
# Version: 5.1-production
#
# Tested against:
#   VyOS 2026.07.x
#   VPP 25.10.x
#
# Data source:
#   vppctl show det44 mappings
#   vppctl show det44 sessions
#   vppctl show buffers
#   vppctl show hardware-interfaces
#   vppctl show interface
#   vppctl show node counters
#   vppctl show runtime
#
# Output:
#   /run/node_exporter/collector/vpp_metrics.prom
#
# IMPORTANT:
#   - no "clear" commands are executed
#   - no VPP state is modified
#   - all counters are read-only
#   - node counters are aggregated across VPP workers
###############################################################################

set -u
set -o pipefail

###############################################################################
# Configuration
###############################################################################

TEXTFILE_DIR="/run/node_exporter/collector"
PROM_FILE="${TEXTFILE_DIR}/vpp_metrics2.prom"
TMP_FILE="${PROM_FILE}.tmp.$$"

VPPCTL="/usr/bin/vppctl"

# DET44 session capacity per inside host.
# This is a VPP DET44 session-slot limit, NOT the number of ports.
# Keep configurable because it is an implementation/configuration parameter.
DET44_SESSION_CAPACITY_PER_USER=1000

# DET44 ports-per-host is NEVER configured statically here.
# The exporter takes the value reported by:
#   vppctl show det44 mappings
# and calculates a CIDR-based fallback only if VPP does not print it.
#
# With /24 -> /30:
#   sharing ratio = 256 / 4 = 64
#   usable port slots = 64 * 1008 = 64512
#   ports/host = 64512 / 64 = 1008
#
# With /24 -> /32:
#   sharing ratio = 256 / 1 = 256
#   ports/host = 64512 / 256 = 252
DET44_USABLE_PORT_SLOTS=64512

###############################################################################
# Cleanup
###############################################################################

cleanup()
{
    rm -f "$TMP_FILE"
}

trap cleanup EXIT INT TERM

###############################################################################
# Prepare
###############################################################################

mkdir -p "$TEXTFILE_DIR" || exit 1

if [ ! -x "$VPPCTL" ]; then
    echo "ERROR: $VPPCTL not found or not executable" >&2
    exit 1
fi

: > "$TMP_FILE"

###############################################################################
# Temporary command files
###############################################################################

MAP_FILE="/tmp/vpp_metrics_v5_map.$$"
SES_FILE="/tmp/vpp_metrics_v5_ses.$$"
BUF_FILE="/tmp/vpp_metrics_v5_buf.$$"
HW_FILE="/tmp/vpp_metrics_v5_hw.$$"
IF_FILE="/tmp/vpp_metrics_v5_if.$$"
NODE_FILE="/tmp/vpp_metrics_v5_node.$$"
RUN_FILE="/tmp/vpp_metrics_v5_run.$$"

rm -f \
    "$MAP_FILE" \
    "$SES_FILE" \
    "$BUF_FILE" \
    "$HW_FILE" \
    "$IF_FILE" \
    "$NODE_FILE" \
    "$RUN_FILE"

cleanup_extra()
{
    rm -f \
        "$MAP_FILE" \
        "$SES_FILE" \
        "$BUF_FILE" \
        "$HW_FILE" \
        "$IF_FILE" \
        "$NODE_FILE" \
        "$RUN_FILE"
}

trap 'cleanup; cleanup_extra' EXIT INT TERM

###############################################################################
# Execute VPP commands
###############################################################################

"$VPPCTL" show det44 mappings > "$MAP_FILE" 2>/dev/null
MAP_RC=$?

"$VPPCTL" show det44 sessions > "$SES_FILE" 2>/dev/null
SES_RC=$?

"$VPPCTL" show buffers > "$BUF_FILE" 2>/dev/null
BUF_RC=$?

"$VPPCTL" show hardware-interfaces > "$HW_FILE" 2>/dev/null
HW_RC=$?

"$VPPCTL" show interface > "$IF_FILE" 2>/dev/null
IF_RC=$?

"$VPPCTL" show node counters > "$NODE_FILE" 2>/dev/null
NODE_RC=$?

"$VPPCTL" show runtime > "$RUN_FILE" 2>/dev/null
RUN_RC=$?

###############################################################################
# Exporter health
###############################################################################

cat >> "$TMP_FILE" <<'EOF'
# HELP vpp_metrics_up VPP metrics collection status
# TYPE vpp_metrics_up gauge
EOF

if [ "$MAP_RC" -eq 0 ] && [ -s "$MAP_FILE" ]; then
    echo "vpp_metrics_up 1" >> "$TMP_FILE"
else
    echo "vpp_metrics_up 0" >> "$TMP_FILE"
fi

cat >> "$TMP_FILE" <<'EOF'
# HELP vpp_metrics_command_success VPP command execution status
# TYPE vpp_metrics_command_success gauge
EOF

echo "vpp_metrics_command_success{command=\"det44_mappings\"} $([ "$MAP_RC" -eq 0 ] && echo 1 || echo 0)" >> "$TMP_FILE"
echo "vpp_metrics_command_success{command=\"det44_sessions\"} $([ "$SES_RC" -eq 0 ] && echo 1 || echo 0)" >> "$TMP_FILE"
echo "vpp_metrics_command_success{command=\"buffers\"} $([ "$BUF_RC" -eq 0 ] && echo 1 || echo 0)" >> "$TMP_FILE"
echo "vpp_metrics_command_success{command=\"hardware_interfaces\"} $([ "$HW_RC" -eq 0 ] && echo 1 || echo 0)" >> "$TMP_FILE"
echo "vpp_metrics_command_success{command=\"interfaces\"} $([ "$IF_RC" -eq 0 ] && echo 1 || echo 0)" >> "$TMP_FILE"
echo "vpp_metrics_command_success{command=\"node_counters\"} $([ "$NODE_RC" -eq 0 ] && echo 1 || echo 0)" >> "$TMP_FILE"
echo "vpp_metrics_command_success{command=\"runtime\"} $([ "$RUN_RC" -eq 0 ] && echo 1 || echo 0)" >> "$TMP_FILE"

###############################################################################
# 1. DET44 MAPPINGS
###############################################################################

if [ "$MAP_RC" -eq 0 ] && [ -s "$MAP_FILE" ]; then

cat >> "$TMP_FILE" <<'EOF'
# HELP vpp_cgnat_mapping_info DET44 mapping information
# TYPE vpp_cgnat_mapping_info gauge

# HELP vpp_cgnat_mapping_sharing_ratio Number of inside hosts sharing one outside IP
# TYPE vpp_cgnat_mapping_sharing_ratio gauge

# HELP vpp_cgnat_mapping_ports_per_host Port slots allocated to each inside host
# TYPE vpp_cgnat_mapping_ports_per_host gauge

# HELP vpp_cgnat_mapping_inside_hosts Number of inside hosts in mapping
# TYPE vpp_cgnat_mapping_inside_hosts gauge

# HELP vpp_cgnat_mapping_outside_ips Number of outside IP addresses in mapping
# TYPE vpp_cgnat_mapping_outside_ips gauge

# HELP vpp_cgnat_mapping_session_capacity Maximum DET44 session slots in mapping
# TYPE vpp_cgnat_mapping_session_capacity gauge

# HELP vpp_cgnat_mapping_port_capacity Maximum theoretical port slots in mapping
# TYPE vpp_cgnat_mapping_port_capacity gauge

# HELP vpp_cgnat_mapping_sessions Current active DET44 sessions
# TYPE vpp_cgnat_mapping_sessions gauge

# HELP vpp_cgnat_mapping_session_utilization DET44 session slot utilization
# TYPE vpp_cgnat_mapping_session_utilization gauge

# HELP vpp_cgnat_mapping_port_utilization_estimate Estimated port utilization based on sessions
# TYPE vpp_cgnat_mapping_port_utilization_estimate gauge
EOF

awk -v session_cap="$DET44_SESSION_CAPACITY_PER_USER" -v usable_ports="$DET44_USABLE_PORT_SLOTS" '
function esc(s) {
    gsub(/\\/,"\\\\",s)
    gsub(/"/,"\\\"",s)
    return s
}

BEGIN {
    inside=""
    outside=""
    ratio=0
    ports=0
    sessions=0
}

{
    sub(/\r$/, "", $0)
}

$1=="in" && $3=="out" {
    inside=$2
    outside=$4
    ratio=0
    ports=0
    sessions=0
    next
}

$1=="outside" && $2=="address" && $3=="sharing" && $4=="ratio:" {
    ratio=$5
    next
}

$1=="number" && $2=="of" && $3=="ports" && $4=="per" && $5=="inside" && $6=="host:" {
    ports=$7
    next
}

$1=="sessions" && $2=="number:" {
    sessions=$3

    split(inside, ia, "/")
    split(outside, oa, "/")

    in_hosts = 2 ^ (32 - ia[2])
    out_ips  = 2 ^ (32 - oa[2])

    # VPP printed values are authoritative.
    # If either value is missing/invalid, derive it from the CIDRs.
    cidr_ratio = 0
    cidr_ports = 0

    if (out_ips > 0)
        cidr_ratio = in_hosts / out_ips

    if (ratio <= 0 && cidr_ratio > 0)
        ratio = cidr_ratio

    if (ports <= 0 && ratio > 0)
        ports = int((usable_ports / ratio) + 0.5)

    session_capacity = in_hosts * session_cap
    port_capacity = in_hosts * ports

    if (session_capacity > 0)
        session_util = sessions / session_capacity
    else
        session_util = 0

    if (port_capacity > 0)
        port_util = sessions / port_capacity
    else
        port_util = 0

    printf "vpp_cgnat_mapping_info{inside=\"%s\",outside_pool=\"%s\"} 1\n", \
        esc(inside), esc(outside)

    printf "vpp_cgnat_mapping_sharing_ratio{inside=\"%s\",outside_pool=\"%s\"} %d\n", \
        esc(inside), esc(outside), ratio

    printf "vpp_cgnat_mapping_ports_per_host{inside=\"%s\",outside_pool=\"%s\"} %d\n", \
        esc(inside), esc(outside), ports

    printf "vpp_cgnat_mapping_inside_hosts{inside=\"%s\",outside_pool=\"%s\"} %d\n", \
        esc(inside), esc(outside), in_hosts

    printf "vpp_cgnat_mapping_outside_ips{inside=\"%s\",outside_pool=\"%s\"} %d\n", \
        esc(inside), esc(outside), out_ips

    printf "vpp_cgnat_mapping_session_capacity{inside=\"%s\",outside_pool=\"%s\"} %d\n", \
        esc(inside), esc(outside), session_capacity

    printf "vpp_cgnat_mapping_port_capacity{inside=\"%s\",outside_pool=\"%s\"} %d\n", \
        esc(inside), esc(outside), port_capacity

    printf "vpp_cgnat_mapping_sessions{inside=\"%s\",outside_pool=\"%s\"} %d\n", \
        esc(inside), esc(outside), sessions

    printf "vpp_cgnat_mapping_session_utilization{inside=\"%s\",outside_pool=\"%s\"} %.8f\n", \
        esc(inside), esc(outside), session_util

    printf "vpp_cgnat_mapping_port_utilization_estimate{inside=\"%s\",outside_pool=\"%s\"} %.8f\n", \
        esc(inside), esc(outside), port_util

    total_sessions += sessions
    total_session_capacity += session_capacity
    total_port_capacity += port_capacity
}
END {
    printf "# HELP vpp_cgnat_total_sessions Total active DET44 sessions\n"
    printf "# TYPE vpp_cgnat_total_sessions gauge\n"
    printf "vpp_cgnat_total_sessions %d\n", total_sessions

    printf "# HELP vpp_cgnat_total_session_capacity Total DET44 session capacity\n"
    printf "# TYPE vpp_cgnat_total_session_capacity gauge\n"
    printf "vpp_cgnat_total_session_capacity %d\n", total_session_capacity

    printf "# HELP vpp_cgnat_total_port_capacity Total theoretical DET44 port capacity\n"
    printf "# TYPE vpp_cgnat_total_port_capacity gauge\n"
    printf "vpp_cgnat_total_port_capacity %d\n", total_port_capacity

    if (total_session_capacity > 0)
        printf "# HELP vpp_cgnat_total_session_utilization Total DET44 session utilization\n"
        printf "# TYPE vpp_cgnat_total_session_utilization gauge\n"
        printf "vpp_cgnat_total_session_utilization %.8f\n", \
            total_sessions / total_session_capacity
}
' "$MAP_FILE" >> "$TMP_FILE"

fi

###############################################################################
# 2. DET44 SESSIONS / USERS
###############################################################################

if [ "$SES_RC" -eq 0 ] && [ -s "$SES_FILE" ]; then

cat >> "$TMP_FILE" <<'EOF'
# HELP vpp_cgnat_user_sessions Active DET44 sessions per inside host
# TYPE vpp_cgnat_user_sessions gauge

# HELP vpp_cgnat_user_session_capacity Maximum DET44 session slots per inside host
# TYPE vpp_cgnat_user_session_capacity gauge

# HELP vpp_cgnat_user_session_utilization DET44 session slot utilization per inside host
# TYPE vpp_cgnat_user_session_utilization gauge

# HELP vpp_cgnat_user_external_hosts Number of unique external hosts contacted by inside host
# TYPE vpp_cgnat_user_external_hosts gauge

# HELP vpp_cgnat_user_sessions_state Active DET44 sessions by state
# TYPE vpp_cgnat_user_sessions_state gauge

# HELP vpp_cgnat_protocol_sessions Active DET44 sessions by protocol
# TYPE vpp_cgnat_protocol_sessions gauge

# HELP vpp_cgnat_protocol_share Active DET44 session share by protocol
# TYPE vpp_cgnat_protocol_share gauge

# HELP vpp_cgnat_real_ip_sessions Active sessions per exact external Real IP
# TYPE vpp_cgnat_real_ip_sessions gauge
EOF

awk -v session_cap="$DET44_SESSION_CAPACITY_PER_USER" '
function esc(s) {
    gsub(/\\/,"\\\\",s)
    gsub(/"/,"\\\"",s)
    return s
}

function state_proto(s) {
    if (s ~ /^tcp-/) return "tcp"
    if (s ~ /^udp-/) return "udp"
    if (s ~ /^icmp-/) return "icmp"
    return "unknown"
}

{
    sub(/\r$/, "", $0)
}

$1=="in" {

    split($2, inparts, ":")
    inside=inparts[1]

    out_ip=""
    state="unknown"
    expire=""

    if ($3=="out") {
        split($4, outparts, ":")
        out_ip=outparts[1]
    }

    for (i=5; i<=NF; i++) {
        if ($i=="state:") {
            state=$(i+1)
        }

        if ($i=="expire:") {
            expire=$(i+1)
        }
    }

    if (inside == "")
        next

    user_sessions[inside]++

    if (out_ip != "") {
        real_ip_sessions[out_ip]++
        user_external[inside SUBSEP out_ip]=1
    }

    proto=state_proto(state)
    user_state[inside SUBSEP state]++
    protocol_sessions[proto]++

    total_user_sessions++

    next
}

END {

    for (u in user_sessions) {

        printf "vpp_cgnat_user_sessions{inside=\"%s\"} %d\n", \
            esc(u), user_sessions[u]

        printf "vpp_cgnat_user_session_capacity{inside=\"%s\"} 1000\n", \
            esc(u)

        printf "vpp_cgnat_user_session_utilization{inside=\"%s\"} %.8f\n", \
            esc(u), user_sessions[u] / session_cap

        ext_count=0

        for (x in user_external) {
            split(x, p, SUBSEP)
            if (p[1] == u)
                ext_count++
        }

        printf "vpp_cgnat_user_external_hosts{inside=\"%s\"} %d\n", \
            esc(u), ext_count
    }

    for (x in user_state) {

        split(x, p, SUBSEP)

        printf "vpp_cgnat_user_sessions_state{inside=\"%s\",state=\"%s\",protocol=\"%s\"} %d\n", \
            esc(p[1]), esc(p[2]), state_proto(p[2]), user_state[x]
    }

    for (proto in protocol_sessions) {
        printf "vpp_cgnat_protocol_sessions{protocol=\"%s\"} %d\n", \
            esc(proto), protocol_sessions[proto]
    }

    if (total_user_sessions > 0) {
        for (proto in protocol_sessions) {
            printf "vpp_cgnat_protocol_share{protocol=\"%s\"} %.8f\n", \
                esc(proto), protocol_sessions[proto] / total_user_sessions
        }
    }

    for (ip in real_ip_sessions) {

        printf "vpp_cgnat_real_ip_sessions{real_ip=\"%s\"} %d\n", \
            esc(ip), real_ip_sessions[ip]
    }

    printf "# HELP vpp_cgnat_active_users Number of inside hosts with active DET44 sessions\n"
    printf "# TYPE vpp_cgnat_active_users gauge\n"

    active=0
    for (u in user_sessions)
        active++

    printf "vpp_cgnat_active_users %d\n", active
}
' "$SES_FILE" >> "$TMP_FILE"

fi

###############################################################################
# 3. DET44 REAL IP CAPACITY
###############################################################################

if [ "$MAP_RC" -eq 0 ] && [ -s "$MAP_FILE" ]; then

cat >> "$TMP_FILE" <<'EOF'
# HELP vpp_cgnat_real_ip_user_capacity Maximum inside hosts sharing one outside IP
# TYPE vpp_cgnat_real_ip_user_capacity gauge

# HELP vpp_cgnat_real_ip_session_capacity Maximum DET44 session slots theoretically assigned to one outside IP
# TYPE vpp_cgnat_real_ip_session_capacity gauge
EOF

awk -v session_cap="$DET44_SESSION_CAPACITY_PER_USER" '
{
    sub(/\r$/, "", $0)
}

$1=="in" && $3=="out" {
    inside=$2
    outside=$4
    ratio=0
    next
}

$1=="outside" && $2=="address" && $3=="sharing" && $4=="ratio:" {
    ratio=$5
    next
}

$1=="sessions" && $2=="number:" {

    split(outside, p, "/")

    outside_ips=2 ^ (32-p[2])

    split(inside, ia, "/")
    in_hosts=2 ^ (32 - ia[2])

    if (outside_ips > 0)
        cidr_ratio=in_hosts / outside_ips
    else
        cidr_ratio=0

    if (ratio <= 0)
        ratio=cidr_ratio

    users_per_ip=ratio

    session_capacity=users_per_ip * session_cap

    # Expand outside CIDR.
    split(p[1], oct, ".")

    base=(oct[1]*256*256*256) + \
         (oct[2]*256*256) + \
         (oct[3]*256) + \
         oct[4]

    for (i=0; i<outside_ips; i++) {

        n=base+i

        a=int(n/(256*256*256))
        r=n%(256*256*256)

        b=int(r/(256*256))
        r=r%(256*256)

        c=int(r/256)
        d=r%256

        ip=a "." b "." c "." d

        printf "vpp_cgnat_real_ip_user_capacity{real_ip=\"%s\"} %d\n", \
            ip, users_per_ip

        printf "vpp_cgnat_real_ip_session_capacity{real_ip=\"%s\"} %d\n", \
            ip, session_capacity
    }
}
' "$MAP_FILE" >> "$TMP_FILE"

fi

###############################################################################
# 4. DET44 OUT OF PORTS
###############################################################################

if [ "$NODE_RC" -eq 0 ] && [ -s "$NODE_FILE" ]; then

cat >> "$TMP_FILE" <<'EOF'
# HELP vpp_cgnat_out_of_ports_total Total DET44 packets rejected because no ports were available
# TYPE vpp_cgnat_out_of_ports_total counter
EOF

awk '
$2=="det44-in2out" && $NF=="error" {

    reason=""

    for (i=3; i<NF; i++) {
        if (reason != "")
            reason=reason " "
        reason=reason $i
    }

    if (reason=="Out of ports")
        total += $1
}

END {
    printf "vpp_cgnat_out_of_ports_total %d\n", total+0
}
' "$NODE_FILE" >> "$TMP_FILE"

fi

###############################################################################
# 5. VPP NODE COUNTERS
#
# IMPORTANT:
# "show node counters" may contain repeated node/reason entries from
# different VPP workers.
#
# Aggregate by:
#   node + reason + severity
###############################################################################

if [ "$NODE_RC" -eq 0 ] && [ -s "$NODE_FILE" ]; then

cat >> "$TMP_FILE" <<'EOF'
# HELP vpp_node_counter_total VPP node counters aggregated across workers
# TYPE vpp_node_counter_total counter
EOF

awk '
NR==1 {
    next
}

$1 ~ /^[0-9]+$/ && NF >= 4 {

    count=$1
    node=$2
    severity=$NF

    reason=""

    for (i=3; i<NF; i++) {
        if (reason != "")
            reason=reason " "
        reason=reason $i
    }

    if (reason=="")
        next

    key=node SUBSEP reason SUBSEP severity

    counters[key]+=count
}

END {

    for (key in counters) {

        split(key, p, SUBSEP)

        node=p[1]
        reason=p[2]
        severity=p[3]

        gsub(/\\/,"\\\\",node)
        gsub(/"/,"\\\"",node)

        gsub(/\\/,"\\\\",reason)
        gsub(/"/,"\\\"",reason)

        gsub(/\\/,"\\\\",severity)
        gsub(/"/,"\\\"",severity)

        printf "vpp_node_counter_total{node=\"%s\",reason=\"%s\",severity=\"%s\"} %d\n", \
            node, reason, severity, counters[key]
    }
}
' "$NODE_FILE" >> "$TMP_FILE"

fi

###############################################################################
# 6. HARDWARE RX MISSED / NO BUFFER
###############################################################################

if [ "$HW_RC" -eq 0 ] && [ -s "$HW_FILE" ]; then

cat >> "$TMP_FILE" <<'EOF'
# HELP vpp_hw_rx_missed Hardware level RX missed packets
# TYPE vpp_hw_rx_missed counter

# HELP vpp_hw_rx_no_buffer Hardware RX out of buffer drops
# TYPE vpp_hw_rx_no_buffer counter
EOF

awk '
{
    sub(/\r$/, "", $0)
}

$0 !~ /^[ \t]/ && NF > 0 && $1 != "Name" {
    iface=$1
}

/^[ \t]+rx missed[ \t]+[0-9]+$/ {
    if (iface != "")
        printf "vpp_hw_rx_missed{interface=\"%s\"} %s\n", iface, $NF
}


/^[ \t]+rx out of buffer[ \t]+[0-9]+$/ {
    if (iface != "")
        printf "vpp_hw_rx_no_buffer{interface=\"%s\"} %s\n", iface, $NF
}

/^[ \t]+rx no buffer[ \t]+[0-9]+$/ {
    if (iface != "")
        printf "vpp_hw_rx_no_buffer{interface=\"%s\"} %s\n", iface, $NF
}

/^[ \t]+rx_no_buffer[ \t]+[0-9]+$/ {
    if (iface != "")
        printf "vpp_hw_rx_no_buffer{interface=\"%s\"} %s\n", iface, $NF
}
' "$HW_FILE" >> "$TMP_FILE"

fi

###############################################################################
# 7. INTERFACE COUNTERS
###############################################################################

if [ "$IF_RC" -eq 0 ] && [ -s "$IF_FILE" ]; then

cat >> "$TMP_FILE" <<'EOF'
# HELP vpp_if_rx_bytes Interface RX bytes
# TYPE vpp_if_rx_bytes counter

# HELP vpp_if_tx_bytes Interface TX bytes
# TYPE vpp_if_tx_bytes counter

# HELP vpp_if_rx_packets Interface RX packets
# TYPE vpp_if_rx_packets counter

# HELP vpp_if_tx_packets Interface TX packets
# TYPE vpp_if_tx_packets counter

# HELP vpp_if_drops Interface software drops
# TYPE vpp_if_drops counter
EOF

awk '
function esc(s) {
    gsub(/\\/,"\\\\",s)
    gsub(/"/,"\\\"",s)
    return s
}

{
    sub(/\r$/, "", $0)
}

$0 !~ /^[ \t]/ && NF >= 2 && $1 != "Name" {
    iface=$1
}

$1=="rx" && $2=="packets" && iface!="" {
    printf "vpp_if_rx_packets{interface=\"%s\"} %s\n", esc(iface), $NF
}

$1=="rx" && $2=="bytes" && iface!="" {
    printf "vpp_if_rx_bytes{interface=\"%s\"} %s\n", esc(iface), $NF
}

$1=="tx" && $2=="packets" && iface!="" {
    printf "vpp_if_tx_packets{interface=\"%s\"} %s\n", esc(iface), $NF
}

$1=="tx" && $2=="bytes" && iface!="" {
    printf "vpp_if_tx_bytes{interface=\"%s\"} %s\n", esc(iface), $NF
}

$1=="drops" && iface!="" {
    printf "vpp_if_drops{interface=\"%s\"} %s\n", esc(iface), $NF
}
' "$IF_FILE" >> "$TMP_FILE"

fi

###############################################################################
# 8. BUFFERS
###############################################################################

if [ "$BUF_RC" -eq 0 ] && [ -s "$BUF_FILE" ]; then

cat >> "$TMP_FILE" <<'EOF'
# HELP vpp_buffers_avail Available buffers reported by VPP
# TYPE vpp_buffers_avail gauge

# HELP vpp_buffers_total Total buffers reported by VPP
# TYPE vpp_buffers_total gauge

# HELP vpp_buffers_cached Cached buffers reported by VPP
# TYPE vpp_buffers_cached gauge

# HELP vpp_buffers_used Used buffers reported by VPP
# TYPE vpp_buffers_used gauge

# HELP vpp_buffers_used_ratio Used / (used + avail) buffer ratio
# TYPE vpp_buffers_used_ratio gauge
EOF

awk '
NR==1 {
    next
}

$1 ~ /^default-numa-/ && NF >= 9 {

    pool=$1
    total=$6
    avail=$7
    cached=$8
    used=$9

    printf "vpp_buffers_avail{pool=\"%s\"} %s\n", pool, avail
    printf "vpp_buffers_total{pool=\"%s\"} %s\n", pool, total
    printf "vpp_buffers_cached{pool=\"%s\"} %s\n", pool, cached
    printf "vpp_buffers_used{pool=\"%s\"} %s\n", pool, used

    denom=used+avail

    if (denom > 0)
        printf "vpp_buffers_used_ratio{pool=\"%s\"} %.8f\n", pool, used/denom
    else
        printf "vpp_buffers_used_ratio{pool=\"%s\"} 0\n", pool
}
' "$BUF_FILE" >> "$TMP_FILE"

fi

###############################################################################
# 9. VPP RUNTIME
###############################################################################

if [ "$RUN_RC" -eq 0 ] && [ -s "$RUN_FILE" ]; then

cat >> "$TMP_FILE" <<'EOF'
# HELP vpp_runtime_vector_rate Average VPP vector rate per thread
# TYPE vpp_runtime_vector_rate gauge

# HELP vpp_runtime_loops_sec VPP loops per second per thread
# TYPE vpp_runtime_loops_sec gauge

# HELP vpp_runtime_average_vectors Average vectors per node per thread
# TYPE vpp_runtime_average_vectors gauge
EOF

awk '
function esc(s) {
    gsub(/\\/,"\\\\",s)
    gsub(/"/,"\\\"",s)
    return s
}

function clean(s) {
    gsub(/,/, "", s)
    gsub(/\r/, "", s)
    return s
}

function valid_number(s) {
    s=clean(s)
    if (s == "NaN" || s == "+Inf" || s == "-Inf") return 1
    if (s ~ /^[+-]?[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?$/) return 1
    if (s ~ /^[+-]?[.][0-9]+([eE][+-]?[0-9]+)?$/) return 1
    return 0
}

$1=="Thread" {
    thread=""
    for (i=1; i<=NF; i++) {
        if ($i ~ /^vpp_(main|wk_[0-9]+)$/) {
            thread=$i
            break
        }
    }
    next
}

thread != "" {
    # vectors/node may occur on Time rows or other formatting variants.
    for (i=1; i<=NF; i++) {
        if ($i=="vectors/node" && i<NF) {
            avg=$(i+1)
            if (valid_number(avg))
                printf "vpp_runtime_average_vectors{thread=\"%s\"} %s\n", esc(thread), clean(avg)
        }
    }

    # Parse vector rates by label, never by fixed column position.
    if ($1=="vector" && $2=="rates") {
        in_rate=""; out_rate=""; drop_rate=""
        for (i=1; i<NF; i++) {
            token=$i
            gsub(/,/, "", token)
            if (token=="in") {
                v=$(i+1); if (valid_number(v)) in_rate=clean(v)
            }
            if (token=="out") {
                v=$(i+1); if (valid_number(v)) out_rate=clean(v)
            }
            if (token=="drop") {
                v=$(i+1); if (valid_number(v)) drop_rate=clean(v)
            }
        }
        if (in_rate!="") printf "vpp_runtime_vector_rate{thread=\"%s\",direction=\"in\"} %s\n", esc(thread), in_rate
        if (out_rate!="") printf "vpp_runtime_vector_rate{thread=\"%s\",direction=\"out\"} %s\n", esc(thread), out_rate
        if (drop_rate!="") printf "vpp_runtime_vector_rate{thread=\"%s\",direction=\"drop\"} %s\n", esc(thread), drop_rate
    }

    # loops/sec can appear independently of vector rates.
    for (i=1; i<NF; i++) {
        if ($i=="loops/sec") {
            loops=$(i+1)
            if (valid_number(loops))
                printf "vpp_runtime_loops_sec{thread=\"%s\"} %s\n", esc(thread), clean(loops)
            break
        }
    }
}
' "$RUN_FILE" >> "$TMP_FILE"

fi

###############################################################################
# 10. Exporter timestamp
###############################################################################

cat >> "$TMP_FILE" <<EOF
# HELP vpp_metrics_last_collection_timestamp_seconds Unix timestamp of successful metric file generation
# TYPE vpp_metrics_last_collection_timestamp_seconds gauge
vpp_metrics_last_collection_timestamp_seconds $(date +%s)
EOF

###############################################################################
# 11. Basic validation
###############################################################################

if [ ! -s "$TMP_FILE" ]; then
    echo "ERROR: generated metrics file is empty" >&2
    exit 1
fi

###############################################################################
# 12. Duplicate sample detection
#
# Prometheus does not allow two samples with the same complete label set.
# Detect obvious duplicates before publishing.
###############################################################################

DUPLICATES=$(
    awk '
    /^vpp_[a-zA-Z0-9_]+{/ {
        line=$0
        sub(/ [^ ]+$/, "", line)
        samples[line]++
    }
    END {
        for (x in samples)
            if (samples[x] > 1)
                print x
    }
    ' "$TMP_FILE"
)

if [ -n "$DUPLICATES" ]; then
    echo "ERROR: duplicate Prometheus samples detected; keeping previous file" >&2
    echo "$DUPLICATES" >&2
    exit 1
fi

###############################################################################
# 13. Atomic publish
###############################################################################

chmod 644 "$TMP_FILE"

mv -f "$TMP_FILE" "$PROM_FILE"

exit 0
