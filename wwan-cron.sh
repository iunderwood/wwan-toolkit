#!/usr/bin/bash

# Check sudo

if [ $EUID -ne 0 ] ; then
        echo "* This script must be run as root."
        exit
fi

echo "-----[ Start ]-----"
date

# Make sure we have a QMI drier loaded

if [ $(lsusb -t | grep -ic "qmi_wwan" ) -ge 1 ] ; then
        echo "* WMI Driver is loaded"
else
        echo "* QMI Driver is not found.  Exiting."
        exit
fi

# Check for our first run

if [[ -f /tmp/wwan0-init.txt ]] ; then
        echo "* First Run Already Done"
else
        echo "* Setting QMI Mode"
        qmicli -p -d /dev/cdc-wdm0 --wds-get-packet-service-status > /tmp/wwan0-init.txt
fi

# Check Current Status

qmicli -p -d /dev/cdc-wdm0 --wds-get-packet-service-status > /tmp/wwan-ps-status.txt

wwan0_status=$(sed -n "s/.*status: '\(.*\)'/\1/p" /tmp/wwan-ps-status.txt)

if [ $wwan0_status == 'disconnected' ] ; then
        echo "* Modem is Disconnected"
else
        echo "* Modem Status: $wwan0_status"

        if [ $(ip link show wwan0 | grep -c DOWN) -ge 1 ] ; then
                echo "* Bringing wwan0 up"
                ip link set wwan0 up
                sleep 1
        else
                echo "* wwan0 link is up."
                exit
        fi
fi

# Check raw_ip

if grep -q "Y" /sys/class/net/wwan0/qmi/raw_ip ; then
        echo "* QMI Raw IP Enabled"
else
        echo "* QMI Raw IP Not Enabled ... enabling."
        ip link set wwan0 down
        sleep 1
        echo 'Y' | tee /sys/class/net/wwan0/qmi/raw_ip > /dev/null
        ip link set wwan0 up
        sleep 1
fi

# Verify Data Format

qmicli -p -d /dev/cdc-wdm0 --wda-get-data-format > /tmp/wwan-df.txt

if grep -q "raw-ip" /tmp/wwan-df.txt ; then
        echo "* Raw IP Data Format"
else
        echo "* Fixing Data Format" Here
        exit
        sleep 1
fi

rm /tmp/wwan-df.txt

# Connect to the APN, if we are OutOfCall

qmicli -p -d /dev/cdc-wdm0 --wds-get-current-settings > /tmp/wwan-settings.txt 2> /tmp/wwan-settings.err

if grep -q "OutOfCall" /tmp/wwan-settings.err ; then
        echo "* Attempting to connect to APN"
        qmicli -p -d /dev/cdc-wdm0 --device-open-net='net-raw-ip|net-no-qos-header' --wds-start-network="apn='myapn.iot',ip-type=4" --client-no-release-cid > /tmp/wwan-conn.txt
        sleep 1
else
        echo "* APN may be connected."
fi

rm /tmp/wwan-settings.txt
rm /tmp/wwan-settings.err

# Check current configuration

qmicli -p -d /dev/cdc-wdm0 --wds-get-current-settings > /tmp/wwan-settings.txt 2> /tmp/wwan-settings.err

ip address show wwan0 > /tmp/wwan0-addr.txt

if grep -q " inet " /tmp/wwan0-addr.txt ; then
        # Extract IPv4 Address Info
        wwan_if_ip=`awk '$1 ~ /^inet$/ {print $2}' /tmp/wwan0-addr.txt`
        echo "* wwan0 IP is: $wwan_if_ip"
else
        echo "* wwan0 IP not applied"
        wwan_if_ip="none"

fi

if grep -q "IPv4" /tmp/wwan-settings.txt ; then
        wwan_radio_ip=`awk '$2 ~ /^address/ {print $3}' /tmp/wwan-settings.txt`
        wwan_radio_mask=`awk '$3 ~ /^mask/ {print $4}' /tmp/wwan-settings.txt`
        wwan_radio_gw=`awk '$2 ~ /^gateway/ {print $4}' /tmp/wwan-settings.txt`

        if [ "$wwan_radio_mask" == "255.255.255.252" ] ; then 
                wwan_radio_bits="/30"
        elif [ "$wwan_radio_mask" == "255.255.255.248" ] ; then
                wwan_radio_bits="/29"
        elif [ "$wwan_radio_mask" == "255.255.255.240" ] ; then
                wwan_radio_bits="/28"
        elif [ "$wwan_radio_mask" == "255.255.255.224" ] ; then
                wwan_radio_bits="/27"
        fi

        echo "* wwan0 radio IPv4 Set $wwan_radio_ip$wwan_radio_bits --> $wwan_radio_gw"
else
        echo "* wwan0 radio IPv4 Not Set"
        wwan_radio_ip="none"
fi

# Set wwan0 IP address

if [ "$wwan_if_ip" == "none" ] ; then
        if [ "$wwan_radio_ip" == "none" ] ; then
                echo "* No interface IPs to Set!"
                exit
        else
                echo "* Setting IP of wwan0 to $wwan_radio_ip$wwan_radio_bits"
                ip address change $wwan_radio_ip$wwan_radio_bits dev wwan0 

                touch /var/log/wwan.log
                logtimestamp=`date +%Y-%m-%dT%T%z`
                echo "$logtimestamp - %WWAN-5-ADDR_CHANGE: 5G IP is now $wwan_radio_ip$wwan_radio_bits" >> /var/log/wwan.log
                sleep 1
        fi
else
        if [ "$wwan_if_ip" == "$wwan_radio_ip$wwan_radio_bits" ] ; then
                echo "* No interface changes necessary"
        else
                echo "$ Changing address from $wwan_if_ip to $wwan_radio_ip$wwan_radio_bits"
                ip address delete $wwan_if_ip dev wwan0
                ip address change $wwan_radio_ip$wwan_radio_bits dev wwan0

                touch /var/log/wwan.log
                logtimestamp=`date +%Y-%m-%dT%T%z`
                echo "$logtimestamp - %WWAN-5-ADDR_CHANGE: 5G IP is now $wwan_radio_ip$wwan_radio_bits" >> /var/log/wwan.log

                sleep 1
        fi
fi

# Add Routes to 5G Link

route add 10.15.234.12/32 wwan0
