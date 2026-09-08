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

echo -e "${YELLOW}Step 1: Updating package lists and installing dependencies...${NC}"

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

echo -e "${YELLOW}Step 2: Downloading LaLune-OpenWRT-arm64.zip...${NC}"

# Create installation directory
INSTALL_DIR="/root/LaLune"
mkdir -p "$INSTALL_DIR"

# Download the latest release
cd /tmp
curl -L -O https://github.com/Endlad2/LaLune/releases/latest/download/LaLune-OpenWRT-arm64.zip

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to download LaLune${NC}"
    exit 1
fi

echo -e "${GREEN}Download completed successfully${NC}"
echo ""

echo -e "${YELLOW}Step 3: Extracting LaLune to $INSTALL_DIR...${NC}"

# Extract the zip file
unzip -o LaLune-OpenWRT-arm64.zip -d "$INSTALL_DIR"

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to extract LaLune${NC}"
    exit 1
fi

# Clean up temporary zip file
rm -f /tmp/LaLune-OpenWRT-arm64.zip

echo -e "${GREEN}Extraction completed successfully${NC}"
echo ""

# Make the binary executable if it exists
if [ -f "$INSTALL_DIR/LaLune" ]; then
    chmod +x "$INSTALL_DIR/LaLune"
    echo -e "${GREEN}Made LaLune executable${NC}"
elif [ -f "$INSTALL_DIR/LaLune.bin" ]; then
    chmod +x "$INSTALL_DIR/LaLune.bin"
    echo -e "${GREEN}Made LaLune.bin executable${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    Congratulations!                    ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}LaLune has been successfully installed!${NC}"
echo -e "${GREEN}Installation path: $INSTALL_DIR${NC}"
echo ""
echo -e "${YELLOW}To run LaLune, execute:${NC}"
echo -e "  $INSTALL_DIR/LaLune"
echo ""
echo -e "${YELLOW}To add to startup (optional):${NC}"
echo -e "  Add to /etc/rc.local or create an init script"
echo ""
