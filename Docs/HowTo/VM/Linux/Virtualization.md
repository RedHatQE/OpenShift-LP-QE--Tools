# Virtualization
## Host Support for L1 Virtualization.
### Linux
#### HW (CPU) Capability
<details><summary>x86</summary>

```shell
# Checking Host CPU HW L1 Virt. support (Intel: vmx; AMD: svm).
grep -cwE '(vmx|svm)' /proc/cpuinfo                         # OK: > 0
lscpu | grep -E '^(Virtualization|Hypervisor vendor):'      # Generic check.
```
</details>
<details><summary>ARM</summary>

```shell
# Checking Host CPU HW L1 Virt. support.
grep -cwE 'hyp' /proc/cpuinfo                               # OK: > 0
lscpu | grep -E '^(Virtualization|Hypervisor vendor):'      # Generic check.
journalctl -kb | grep -i 'EL2'
```
</details>


#### Kernel Support
<details><summary>KVM</summary>

```shell
# Checking Host Kernel Module KVM is loaded and active.
[ -e /dev/kvm ] && echo 'KVM is active.' || echo 'KVM is NOT active.'
```
</details>


## Host Support for L2 (Nested) Virtualization.
### Linux
#### KVM
<details><summary>Check Status</summary>

```shell
# Checking Host KVM support L2 (Nested) Virt.
cat /sys/module/kvm*/parameters/nested  # On: Y / 1; Off: N / 0
```
</details>
<details><summary>Enable (Intel)</summary>

```shell
{
    # Enabling Host KVM Nested Virt. for Intel.
    echo 'options kvm_intel nested=1' > /etc/modprobe.d/kvm-nested.conf
    modprobe -r kvm_intel
    modprobe kvm_intel
}
```
</details>
<details><summary>Enable (AMD)</summary>

```shell
{
    # Enabling Host KVM Nested Virt. for AMD.
    echo 'options kvm_amd nested=1' > /etc/modprobe.d/kvm-nested.conf
    modprobe -r kvm_amd
    modprobe kvm_amd
}
```
</details>
<details><summary>Enable (ARM)</summary>

```shell
{
    # Enabling Host KVM Nested Virt. for ARM.
    echo 'options kvm nested=1' > /etc/modprobe.d/kvm-nested.conf
    modprobe -r kvm
    modprobe kvm
}
```
</details>
