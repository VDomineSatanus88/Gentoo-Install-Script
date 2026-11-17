# Gentoo-Install-Script
An install script setup for Niri with Dux Material Shell.

How to install (I recommend trying it on a VM)
1. Save the script.
2. Open the terminal and CD to where you saved the install script.
3. Run this command in the terminal...python3 -m http.server 8000
4. Boot into the live Gentoo Minimal ISO.
5. Download the script into the Gentoo Live Environment running...curl -O http://10.0.2.2:8000/gentoo-niri-install.sh
6. Then give the script permission to run...chmod +x gentoo-niri-install.sh
7. Confirm the script is there with...ls -l gentoo-niri-install.sh
8. Run lsblk to find your drive for your VM...such as /dev/vda.
9. Then run the script with this command replacing /dev/vda with your actual drive...DISK=/dev/vda NEW_USER=yourname NEW_HOST=gentoo ./gentoo-niri-install.sh
10. It'll ask you to set up a root and user password at the end...and then it should finish completing the script.
11. Once finished you should be able to simply reboot into the Niri Session running Dux Material Shell.
