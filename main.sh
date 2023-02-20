# Fetch, verify and burn the Arch installation media
wget ${URL}/archlinux-x86_64.iso
wget ${URL}/sha256sums.txt
sha256sum -c sha256sums.txt
sudo dd if=archlinux-x86_64.iso of=/dev/sdb bs=4M status=progress
sudo sync
sudo eject /dev/sdb

# Reboot into USB ...

# Load Norwegian keyboard console layout
loadkeys no

# Verify the boot mode
[[ -d /sys/firmware/efi/efivars ]] || read -p "Reboot and enable UEFI before continuing!"

# Connect to Wi-Fi
wpa_supplicant -B -i wlan0 -c <(wpa_passphrase ${SSID} ${PASSWORD})
dhcpcd wlan0

# Update the system clock
timedatectl status # if ntp is not active, run: timedatectl set-ntp true

# Wipe the hard drive
wipefs -a -f /dev/nvme0n1

# Partition the disk
parted -a optimal /dev/nvme0n1 -s mklabel gpt
parted -a optimal /dev/nvme0n1 -s mkpart esp fat32 1MiB 513MiB
parted -a optimal /dev/nvme0n1 -s mkpart boot btrfs 513MiB 1025MiB
parted -a optimal /dev/nvme0n1 -s mkpart root btrfs 1025MiB 100%
parted -a optimal /dev/nvme0n1 -s set 1 esp on
parted -a optimal /dev/nvme0n1 -s print

# Encrypt the root partition
cryptsetup -v -c aes-xts-plain64 -s 512 -h sha512 -i 5000 --pbkdf argon2id --type luks2 luksFormat /dev/nvme0n1p3
cryptsetup -v --allow-discards luksOpen /dev/nvme0n1p3 cryptroot

# Format all partitions
mkfs.vfat -v -F32 -n ESP /dev/nvme0n1p1
mkfs.btrfs -v -M -L BOOT /dev/nvme0n1p2
mkfs.btrfs -v -L ROOT /dev/mapper/cryptroot

# Create btrfs subvolumes
mount -t btrfs /dev/mapper/cryptroot /mnt/
btrfs subvol create /mnt/@
btrfs subvol create /mnt/@home
btrfs subvol create /mnt/@opt
btrfs subvol create /mnt/@root
btrfs subvol create /mnt/@snapshots
btrfs subvol create /mnt/@srv
btrfs subvol create /mnt/@var_cache
btrfs subvol create /mnt/@var_log
btrfs subvol create /mnt/@var_tmp
umount /mnt/

# Mount all partitions and subvolumes
mount -v -t btrfs -o subvol=@ /dev/mapper/cryptroot /mnt/
mkdir -v -p /mnt/{boot,efi,home,opt,root,.snapshots,srv,var/{cache,log,tmp}}/
mount -v -t btrfs -o compress=zstd,ssd,space_cache=v2,subvol=@home /dev/mapper/cryptroot /mnt/home/
mount -v -t btrfs -o compress=zstd,ssd,space_cache=v2,subvol=@opt /dev/mapper/cryptroot /mnt/opt/
mount -v -t btrfs -o compress=zstd,ssd,space_cache=v2,subvol=@root /dev/mapper/cryptroot /mnt/root/
mount -v -t btrfs -o compress=zstd,ssd,space_cache=v2,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots/
mount -v -t btrfs -o compress=zstd,ssd,space_cache=v2,subvol=@srv /dev/mapper/cryptroot /mnt/srv/
mount -v -t btrfs -o compress=zstd,ssd,space_cache=v2,subvol=@var_cache /dev/mapper/cryptroot /mnt/var/cache/
mount -v -t btrfs -o compress=zstd,ssd,space_cache=v2,subvol=@var_log /dev/mapper/cryptroot /mnt/var/log/
mount -v -t btrfs -o compress=zstd,ssd,space_cache=v2,subvol=@var_tmp /dev/mapper/cryptroot /mnt/var/tmp/
mount -v -t btrfs /dev/nvme0n1p2 /mnt/boot/
mount -v -t vfat /dev/nvme0n1p1 /mnt/efi/

# Optimize pacman
nano /etc/pacman.conf # uncomment Color and [multilib] and add [community-testing]\nUsage=Search Sync
reflector --save /etc/pacman.d/mirrorlist --country Norway,Sweden,Denmark --protocol https --latest 10

# Install essential packages
pacstrap -K /mnt/ base base-devel linux linux-firmware dosfstools btrfs-progs cryptsetup fuse2 fuse3 efibootmgr apparmor audit networkmanager wpa_supplicant iptables-nft n
ano man-db man-pages texinfo

# Copy current pacman config files to the new system
cp -v /etc/pacman.conf /mnt/etc/pacman.conf
cp -v /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

# Generate an fstab file
genfstab -U /mnt/ | tee /mnt/etc/fstab
echo -e "# backup\nUUID= /run/media/user/BACKUP btrfs rw,nosuid,nodev,relatime,space_cache=v2,subvolid=5,subvol=/,uhelper=udisks2 0 0" | tee -a /mnt/etc/fstab
echo -e "# /tmp on tmpfs\ntmpfs / tmp tmpfs size=512m 0 0" | tee -a /mnt/etc/fstab

# Automatically decrypt external hard drive
mkdir -v /etc/luks/
echo "backup UUID=$(blkid -o value -s UUID /dev/sda1) /etc/luks/backup.keyfile" | tee -a /mnt/etc/cryptsetup

# Chroot into the new system
arch-chroot /mnt/ /bin/bash

# Enable nano syntax highlighting
echo 'include "/usr/share/nano/*.nanorc"' | tee -a /etc/nanorc

# Generate locales
echo 'en_US.UTF-8 UTF-8' | tee /etc/locale.gen
locale-gen

# Set the language
echo 'LANGUAGE="en_US:en"' | tee /etc/locale.conf
echo 'LANG="en_US.UTF-8"' | tee -a /etc/locale.conf
echo 'LC_COLLATE="C"' | tee -a /etc/locale.conf

# Set the console keyboard layout
echo 'KEYMAP="no"' | tee /etc/vconsole.conf
echo 'FONT="eurlatgr"' | tee -a /etc/vconsole.conf

# Set the timezone
ln -sf /usr/share/zoneinfo/Europe/Oslo /etc/localtime
hwclock --systohc --utc

# Set the hostname
echo 'host' | tee /etc/hostname

# Configure DNS
nano /etc/systemd/resolved.conf
systemctl enable systemd-resolved.service

# Enable NetworkManager
echo -e '[main]\ndns=systemd-resolved' | tee /etc/NetworkManager/conf.d/dns.conf
echo -e '[connectivity]\nenabled=false' | tee /etc/NetworkManager/conf.d/connectivity.conf
systemctl enable NetworkManager.service

# Enable Nftables
nano /etc/nftables.conf
systemctl enable nftables

# Enable AppArmor and Audit
nano /etc/apparmor.d/usr.bin.NetworkManager /etc/apparmor.d/usr.bin.pipewire /etc/apparmor.d/rhythmbox /etc/apparmor.d/tor /etc/apparmor.d/wireplumber /etc/apparmor.d/wpa_supplicant /etc/apparmor.d/usr.lib.bluetooth.bluetoothd /etc/apparmor.d/usr.lib.systemd.systemd-resolved
systemctl enable apparmor.service
systemctl enable auditd.service

# Enable TRIM
systemctl enable fstrim.timer


# Create an user account with root privileges
echo '%wheel ALL=(ALL:ALL) ALL' | tee -a /etc/sudoers
echo 'password required pam_unix.so sha512 shadow nullok rounds=65535' | tee /etc/pam.d/passwd
useradd -m -d /home/user/ -g users -G wheel -s /bin/bash user
passwd user

# Lock the root account
passwd -l root

# Generate Secure Boot keys and certificates
pacman -S sbctl
sbctl create-keys

# sysctl tweaks
nano /etc/sysctl.d/network.conf
nano /etc/sysctl.d/security.conf

# Blacklist insecure kernel modules
nano /etc/modprobe.d/blacklist

# Install AMD CPU microcode
pacman -S amd-ucode

# Generate a Unified Kernel Image
mkdir -v /etc/kernel/
echo "cryptdevice=UUID=$(blkid -o value -s UUID /dev/nvme0n1p3):cryptroot:allow-discards root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=@ lsm=landlock,lockdo
wn,yama,integrity,apparmor,bpf security=1 apparmor=1 slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 pti=on randomize_kstack_offset=on vsyscall=none debug
fs=off oops=panic lockdown=confidentiality quiet splash loglevel=0 vt.global_cursor_default=0" | tee /etc/kernel/cmdline
nano /etc/mkinitcpio.conf /etc/mkinitcpio.d/linux.preset
mkdir -v -p /efi/EFI/Linux/
mkinitcpio -P

# Sign the UKI
sbctl sign -s /efi/EFI/Linux/linux.efi

# Install a boot loader
bootctl install
nano /efi/loader/loader.conf
nano /efi/loader/entries.arch.conf

# Sign the boot loader
sbctl sign -s /efi/EFI/BOOT/BOOTX64.efi
sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi

# Reboot
exit
sync
umount -v -R /mnt/
cryptsetup -v luksClose /dev/mapper/cryptroot
reboot

# Reconnect to Wi-Fi
nmtui

# Install AMD GPU drivers
sudo pacman -S mesa lib32-mesa xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon
sudo pacman -S libva-mesa-driver lib32-libva-mesa-driver mesa-vdpau lib32-mesa-vdpau

# Install AMD OpenCL drivers
sudo pacman -S community-testing/rocm-device-libs community-testing/comgr community-testing/hsakmt-roct community-testing/hsa-rocr community-testing/rocm-opencl-runtime cl
info

# Enable AMD GPU hardware acceleration
nano /etc/environment

# Install audio server and drivers
sudo pacman -S pipewire lib32-pipewire wireplumber pipewire-alsa pipewire-pulse pipewire-jack pipewire-audio
sudo pacman -S gstreamer gst-libav gst-plugins-base gst-plugins-good gst-plugin-pipewire gstreamer-vaapi

# Enable Wayland (with X11 fallback) for Qt, Gtk and Firefox
nano /etc/environment

# Enable Bluetooth
sudo pacman -S bluez bluez-utils
sudo systemctl enable bluetooth.service

# Install display server
sudo pacman -S wayland xorg-server xorg-xwayland qt5-wayland qt6-wayland
sudo localectl set-x11-keymap no
echo 'needs_root_rights = no' | sudo tee /etc/X11/Xwrapper.config

# Install KDE 5 Plasma
sudo pacman -S plasma phonon-qt5-gstreamer breeze-gtk xdg-desktop-portal xdg-desktop-portal-kde noto-fonts-emoji konsole ttf-cascadia-code dolphin ark

# Remove bloat
sudo pacman -Rs discover drkonqi

# Disable Kwallet
echo '[Wallet]' | tee /home/user/.config/kwalletrc
echo 'Enabled=False' | tee -a /home/user/.config/kwalletrc

# Install SDDM 
# WARNING: this seems broken rn, just login to tty at boot and start KDE with: startplasma-wayland
#mkdir -v ~/.build/ ; cd ~/.build/
#git clone https://aur.archlinux.org/sddm-git.git
#cd sddm-git
#makepkg -si
#cd
#sudo systemctl enable sddm-plymouth.service

# Install Plymouth
mkdir -v ~/.build/ ; cd ~/.build/
git clone https://aur.archlinux.org/plymouth-git.git
cd plymouth-git
makepkg -si
cd
sudo sed -i -e 's/udev/udev plymouth/g' /etc/mkinitcpio.conf
sudo sed -i -e 's/encrypt/plymouth-encrypt/g' /etc/mkinitcpio.conf
sudo mkinitcpio -P

# Install useful applications
sudo pacman -S firefox qbittorrent element-desktop signal-desktop discord irssi yt-dlp
sudo pacman -S vlc kdenlive obs-studio rhythmbox audacity gwenview gimp spectaclez
sudo pacman -S steam lutris
sudo pacman -S libreoffice-fresh okular
sudo pacman -S keepassxc kgpg pwgen bubblewrap libseccomp wipe bleachbit
sudo pacman -S wireshark-qt whois nmap sqlmap aircrack-ng hashcat
sudo pacman -S bash-completion htop neofetch screen code gcc gdb clang llvm lldb strace ltrace valgrind

# Enable Tor
sudo pacman -S tor torsocks nyx
sudo nano /etc/tor/torrc
sudo systemctl enable tor.service

# Install World of Warcraft dependencies
sudo pacman -S --needed wine-staging giflib lib32-giflib libpng lib32-libpng libldap lib32-libldap gnutls lib32-gnutls mpg123 lib32-mpg123 openal lib32-openal v4l-utils li
b32-v4l-utils libpulse lib32-libpulse libgpg-error lib32-libgpg-error alsa-plugins lib32-alsa-plugins alsa-lib lib32-alsa-lib libjpeg-turbo lib32-libjpeg-turbo sqlite lib3
2-sqlite libxcomposite lib32-libxcomposite libxinerama lib32-libgcrypt libgcrypt lib32-libxinerama ncurses lib32-ncurses ocl-icd lib32-ocl-icd libxslt lib32-libxslt libva 
lib32-libva gtk3 lib32-gtk3 gst-plugins-base-libs lib32-gst-plugins-base-libs vulkan-icd-loader lib32-vulkan-icd-loader
sudo nano /etc/systemd/system.conf /etc/systemd/user.conf /etc/security/limits.conf

# Reboot (again)
sudo rm -v /boot/initramfs-*
sudo reboot

# Firefox about:config tweaks
nano ~/.mozilla/firefox/duu8cfjs.default-release/prefs.js
