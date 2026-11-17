# Cluster -- Info -- Networking -- Open Virtual Network
## References
<details><summary>Links</summary>

[Network Bonding for Load Balance](https://github.com/RHsyseng/rhcos-slb)
</details>


## Troubleshooting
### Using `tcpdump` from OVN Pod.
```shell
# Accessing TCP Dump (MUST be as `root`) from Node's Host System.
oc debug Node/...nodeName... -t -- chroot /host/ sh -c '"/proc/$(pgrep ovnkube)/root/usr/sbin/tcpdump" -Z root ...'
```
<details><summary>OCP</summary>

```shell
function ocp--infra--node--tcpdump () {
    ocp--infra--node--con '' '(-t)' sh -c '
        "/proc/$(
            pgrep -f "^/usr/bin/ovnkube --init"
        )/root/usr/sbin/tcpdump" -Z root "$@"
    ' '' "$@"
    return 0
}
```
</details>
<details><summary>Bare Metal</summary>

```shell
function k8s--infra-bm--node--tcpdump () {
    k8s--infra-bm--node--con '' '' '(-t)' "$(
        echo 'sudo "/proc/$(
            pgrep -f "^/usr/bin/ovnkube --init"
        )/root/usr/sbin/tcpdump" -Z root '"${@@Q}"
    )"
    return 0
}
```
</details>
<details><summary>AWS</summary>

```shell
function k8s--infra-aws--node--tcpdump () {
    k8s--infra-aws--node--con '' '' '' '' '(-t)' "$(
        echo 'sudo "/proc/$(
            pgrep -f "^/usr/bin/ovnkube --init"
        )/root/usr/sbin/tcpdump" -Z root '"${@@Q}"
    )"
    return 0
}
```
</details>



## Workflows
<details><summary>Changing NIC (different MAC)</summary>

```shell
# Resetting NM and OVS.
rm "/etc/nmstate/$(hostname -s)."{applied,yml}
systemctl stop NetworkManager.service
rm /etc/NetworkManager/system-connections/*
systemctl stop openvswitch.service
rm /etc/openvswitch/conf.db
systemctl start NetworkManager.service
systemctl start openvswitch.service

# Applying new configuration.
nmstatectl apply ...NMstateCfgPartialWoOVN...
systemctl status nmstate-configuration.service
systemctl status nmstate.service
nmstatectl apply ...NMstateCfgFull...

# Starting K8s Agent.
systemctl start kubelet.service
```
</details>
