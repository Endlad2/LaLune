#!/bin/sh

# LaLune Installation Script
# This script downloads and installs LaLune

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    LaLune Installation Script         ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${YELLOW}Step 1: Installing dependencies...${NC}"

# Update package lists
opkg update

# Install curl if not present
if ! command -v curl >/dev/null 2>&1; then
    echo -e "${YELLOW}Installing curl...${NC}"
    opkg install curl
else
    echo -e "${GREEN}curl is already installed${NC}"
fi

# Install unzip if not present
if ! command -v unzip >/dev/null 2>&1; then
    echo -e "${YELLOW}Installing unzip...${NC}"
    opkg install unzip
else
    echo -e "${GREEN}unzip is already installed${NC}"
fi

echo -e "${GREEN}Dependencies installed successfully${NC}"
echo ""

echo -e "${YELLOW}Step 2: Downloading LaLune...${NC}"

# Create installation directory
INSTALL_DIR="/root/LaLune"
mkdir -p "$INSTALL_DIR"

# Download the latest release
cd "$INSTALL_DIR"
echo "Downloading LaLune-OpenWRT-arm64.zip..."
curl -L -O https://github.com/Endlad2/LaLune/releases/latest/download/LaLune-OpenWRT-arm64.zip

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to download LaLune${NC}"
    exit 1
fi

echo -e "${GREEN}Download completed successfully${NC}"
echo ""

echo -e "${YELLOW}Step 3: Extracting LaLune...${NC}"

# Extract the zip file
unzip -o LaLune-OpenWRT-arm64.zip

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to extract LaLune${NC}"
    exit 1
fi

# Clean up zip file
rm -f LaLune-OpenWRT-arm64.zip

echo -e "${GREEN}Extraction completed successfully${NC}"
echo ""

echo -e "${YELLOW}Step 4: Making csqtt-client-arm64 executable...${NC}"

# Path to the binary
BINARY_PATH="/root/LaLune/LaLune-OpenWRT-arm64/csqtt-client-arm64"

# Check if the binary exists
if [ -f "$BINARY_PATH" ]; then
    chmod +x "$BINARY_PATH"
    echo -e "${GREEN}Made executable: $BINARY_PATH${NC}"
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    Congratulations!                    ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}LaLune has been successfully installed!${NC}"
    echo -e "${GREEN}Installation path: /root/LaLune/LaLune-OpenWRT-arm64/${NC}"
    echo ""
    echo -e "${YELLOW}To run LaLune, execute:${NC}"
    echo -e "  $BINARY_PATH"
    echo ""
    echo -e "${YELLOW}Or create a symlink for easier access:${NC}"
    echo -e "  ln -s $BINARY_PATH /usr/bin/lalune"
    echo -e "  Then run with: lalune"
    echo ""
    echo -e "${YELLOW}To add to startup (optional):${NC}"
    echo -e "  Add to /etc/rc.local"
else
    echo -e "${RED}Error: Binary not found at $BINARY_PATH${NC}"
    echo -e "${YELLOW}Contents of /root/LaLune/:${NC}"
    ls -la /root/LaLune/
    echo ""
    echo -e "${YELLOW}Contents of /root/LaLune/LaLune-OpenWRT-arm64/ (if exists):${NC}"
    ls -la /root/LaLune/LaLune-OpenWRT-arm64/ 2>/dev/null || echo "Directory not found"
    exit 1
fi
