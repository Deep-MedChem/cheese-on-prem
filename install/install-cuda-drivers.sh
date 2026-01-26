#!/bin/sh

# Installing CUDA drivers - Version 535.54.03
echo Installing NVIDIA CUDA Drivers ... 
sudo apt-get update
sudo apt autoremove cuda* nvidia* --purge
sudo /usr/bin/nvidia-uninstall
sudo /usr/local/cuda-X.Y/bin/cuda-uninstall
sudo apt install build-essential gcc dirmngr ca-certificates software-properties-common apt-transport-https dkms curl -y
curl -fSsL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/3bf863cc.pub | sudo gpg --dearmor | sudo tee /usr/share/keyrings/nvidia-drivers.gpg > /dev/null 2>&1
echo 'deb [signed-by=/usr/share/keyrings/nvidia-drivers.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/ /' | sudo tee /etc/apt/sources.list.d/nvidia-drivers.list
sudo apt update
sudo apt install nvidia-driver-535 cuda-drivers-535
# Install Nvidia Container Toolkit
echo "Installing Nvidia Container Toolkit ..."

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo service docker restart
