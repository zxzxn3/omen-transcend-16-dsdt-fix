
**English** · [Human](README.human.md)

## Install Linux on OMEN TRANSCEND 16

```
I use CachyOS, but this probably works on other distros.
```

The HP-OMEN-16 has a flawed dsdt regarding ACPI that crashes any linux relentlessly. To fix this you need to make a dsdt fix when you're on linux, there are a number of discussions about it[^discussions].

```gibberish
I tried to fix the crash the stupidest way at first -- by asking AI when I can't even get the crash log before crashing, and when I can get a log out, it claims ACPI problems are harmless benign errors. 
```

But first you need to be able to boot into a liveusb (also crashes a lot) to install the linux you are gonna fix. To temporarily bypass the crash, press `e` when you see the bootloader, then add `noapic` to the arguments line, this might cause the touchpad to stop working and etc.

When you're on the liveusb, don't hit `launch installer` yet, connect to your network and try `cachyos-rate-mirrors` to reduce your chance of being stuck with a grey `launch installer` button.

```bash
nmcli radio wifi on # turn on wifi
nmcli device wifi # will show all available wifi
nmcli device connect {SSID|Name} # connect to your wifi
# or use iwctl

sudo cachyos-rate-mirrors # rate mirrors, so you don't get stuck at the installer network check
```

After installing Linux, boot into Linux with `noapic`, patch the dsdt[^discussions] (**RECOMMEND**), or try a patcher I wrote with DeepSeek (**USE AT YOUR OWN RISK**):

```bash
curl -fsSL https://raw.githubusercontent.com/zxzxn3/omen-transcend-16-dsdt-fix/main/dsdt-fix.sh | sudo bash
```

Reboot without `noapic`, check with:

```bash
dmesg | grep -i "table override" # should show the "DSDT ... Physical table override"
```

Congratulations, your kernel is saved.

[^discussions]: Community threads and fixes: [Bugzilla #221847](https://bugzilla.kernel.org/show_bug.cgi?id=221847) and the repos listed under [References & credits](README.md#references--credits). 