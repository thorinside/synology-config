# Script to enable port forwarding and IP Masquerading, to share
# the primary internet connection to the second port of DS1512+

action=$1
shift;

local INT_IFACE="eth1"
local IFCFG_FILE="/etc/sysconfig/network-scripts/ifcfg-${INT_IFACE}"
local DHCPD_CONF="/etc/dhcpd/dhcpd.conf"
local RULES_NAT="/etc/firewall_rules_nat.dump"

logerr() { # [logger args] [msgs...]
        local TAG="nat_router"
        [ ! -z $action ] && TAG="${TAG} (${action})"
        logger -p user.err -t "${TAG}" "$@"
}

# Guard to prevent execution if NAT is not supposed to be enabled
[ -e $IFCFG_FILE -a -e ${DHCPD_CONF} ] || { logerr "Missing config files"; exit 1; }

local IPADDR=`get_key_value ${IFCFG_FILE} IPADDR`
local NETMASK=`get_key_value ${IFCFG_FILE} NETMASK`
local IS_ROUTER=`grep option:router ${DHCPD_CONF} | grep -c ${IPADDR}`

[ ${IS_ROUTER} -eq 0 ] && { logerr "Routing mode not enabled on ${INT_IFACE}"; exit 1; }

# Calculate local network CIDR
local CIDR_PREFIX=`ipcalc -p ${IPADDR} ${NETMASK} | cut -d'=' -f2`
local CIDR_IP=`ipcalc -n ${IPADDR} ${NETMASK} | cut -d'=' -f2`
local CIDR="${CIDR_IP}/${CIDR_PREFIX}"

setup_nat() {
        # Enable port forwarding, in case not enabled by default
        echo 1 > /proc/sys/net/ipv4/ip_forward

        # Load the required modules
        /usr/syno/etc.defaults/rc.d/S01iptables.sh load_nat_mod forwarding_test
}

load_nat_rules() {
        if [ -e ${RULES_NAT} ]; then
                /sbin/iptables-restore -n < ${RULES_NAT} &> /dev/null
                if [ $? -eq 0 ]; then
                        logerr "NAT rules loaded successfully"
                else
                        logerr "Error loading NAT rules from: ${RULES_NAT}"
                        exit 1;
                fi
        else
                logerr "No NAT rules found"
        fi

        # Define the masquerading rule
        /sbin/iptables -t nat -D POSTROUTING -s ${CIDR} -j MASQUERADE &> /dev/null   # don't add twice
        /sbin/iptables -t nat -A POSTROUTING -s ${CIDR} -j MASQUERADE
}

save_nat_rules() {
        local TMP_RULES="/tmp/firewall_rules_nat.tmp"

        echo "# $(date)" > ${TMP_RULES}
        echo "*nat" >> ${TMP_RULES}

        /sbin/iptables-save -t nat | grep "\-j DNAT" | uniq >> ${TMP_RULES}

        echo "COMMIT" >> ${TMP_RULES}
        mv -f ${TMP_RULES} ${RULES_NAT}

        logerr "NAT rules saved to ${RULES_NAT}"
}

clear_nat_rules() {
        /sbin/iptables-save -t nat |grep "\-j DNAT" | sed 's/^-A /-D /g' | while read line; do
                if [ ! -z $line ]; then
                        /sbin/iptables -t nat $line &> /dev/null
                fi
        done

        /sbin/iptables -t nat -D POSTROUTING -s ${CIDR} -j MASQUERADE &> /dev/null
}

case "$action" in
        start)
                setup_nat
                load_nat_rules
                ;;
        stop)
                save_nat_rules
                clear_nat_rules
                ;;
        restart)
                save_nat_rules
                clear_nat_rules
                load_nat_rules
                ;;
        *)
                echo "Usage: $0 [start|stop|restart]"
                ;;
esac

exit 0