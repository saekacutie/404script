#!/bin/bash
# ==============================================================================
# REGION SELECTION MODULE
# ==============================================================================

echo -e "  ${CYAN}PLEASE SELECT A REGION TO DEPLOY, PLEASE BE MINDFUL THAT AFTER YOU SELECT A REGION, YOU CANNOT CHANGE OR GO BACK, PLEASE MAKE SURE THAT THE LAB YOU CREATED SUPPORTS THE REGION YOU SELECTED.${RESET}"
echo ""
echo -e "  ${YELLOW}1) us-central1${RESET}"
echo -e "  ${YELLOW}2) us-east1${RESET}"
echo -e "  ${YELLOW}3) us-west1${RESET}"
echo -e "  ${YELLOW}4) asia-east1${RESET}"
echo -e "  ${YELLOW}5) asia-southeast1${RESET}"
echo -e "  ${YELLOW}6) europe-west1${RESET}"
echo -e "  ${YELLOW}7) europe-west4${RESET}"
echo ""
read -r -p "$(echo -e "  ${CYAN}CHOICE [1-7]: ${RESET}")" REGION_CHOICE

case "$REGION_CHOICE" in
    1) REGION="us-central1";;
    2) REGION="us-east1";;
    3) REGION="us-west1";;
    4) REGION="asia-east1";;
    5) REGION="asia-southeast1";;
    6) REGION="europe-west1";;
    7) REGION="europe-west4";;
    *) REGION="us-central1";;
esac

export REGION
echo -e "  ${GREEN}REGION: ${REGION}${RESET}"
echo ""
