#!/bin/bash
set -e

# ==========================================================
# CONFIG
# ==========================================================
REGION="ap-south-1"
APP_USER="ec2-user"
APP_HOME="/home/ec2-user"

GITHUB_REPO="https://github.com/avijitmajumder2050/marketsmith_ec2.git"

APP_NAME="marketsmithindia-bot"

S3_BUCKET="s3://dhan-trading-data"
S3_PREFIX="trading-bot"

LOGFILE="/var/log/${APP_NAME}.log"
BOOTLOG="/var/log/${APP_NAME}-bootstrap.log"

PLAYWRIGHT_PATH="${APP_HOME}/playwright-browsers"

exec > >(tee -a ${BOOTLOG}) 2>&1

echo "======================================="
echo "Starting EC2 Bootstrap"
echo "======================================="

# ==========================================================
# OS UPDATE
# ==========================================================
sudo yum update -y

sudo timedatectl set-timezone Asia/Kolkata

# ==========================================================
# INSTALL PACKAGES
# ==========================================================
sudo yum install -y \
python3 \
python3-pip \
git \
awscli

echo "Packages installed"

# ==========================================================
# PLAYWRIGHT LINUX DEPENDENCIES
# ==========================================================
sudo yum install -y \
atk \
cups-libs \
gtk3 \
libXcomposite \
libXcursor \
libXdamage \
libXext \
libXi \
libXrandr \
libXScrnSaver \
libXtst \
pango \
alsa-lib \
libX11 \
libX11-xcb \
libxcb \
libXfixes \
libXrender \
cairo \
gdk-pixbuf2 \
fontconfig \
freetype

# ==========================================================
# CLONE REPO
# ==========================================================
cd ${APP_HOME}

REPO_NAME=$(basename ${GITHUB_REPO} .git)

if [ ! -d "${REPO_NAME}" ]; then
    git clone ${GITHUB_REPO}
fi

sudo chown -R ${APP_USER}:${APP_USER} ${REPO_NAME}

cd ${REPO_NAME}

# ==========================================================
# PYTHON VENV
# ==========================================================
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi

source venv/bin/activate

# ==========================================================
# INSTALL PYTHON PACKAGES
# ==========================================================
pip install --upgrade setuptools wheel

pip install \
playwright \
requests \
pandas \
boto3 \
beautifulsoup4

# ==========================================================
# INSTALL REQUIREMENTS
# ==========================================================
if [ -f requirements.txt ]; then
    pip install -r requirements.txt
fi

# ==========================================================
# INSTALL PLAYWRIGHT BROWSER
# ==========================================================
mkdir -p ${PLAYWRIGHT_PATH}

export PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_PATH}

python -m playwright install chromium

echo "Installed browsers:"

find ${PLAYWRIGHT_PATH} -type f | head

# ==========================================================
# LOG FILE
# ==========================================================
sudo touch ${LOGFILE}

sudo chown ${APP_USER}:${APP_USER} ${LOGFILE}

sudo chmod 664 ${LOGFILE}

# ==========================================================
# S3 UPLOAD SCRIPT
# ==========================================================
sudo tee /usr/local/bin/upload-bot-log.sh > /dev/null <<EOF
#!/bin/bash

aws s3 cp \
${LOGFILE} \
${S3_BUCKET}/${S3_PREFIX}/logs/${APP_NAME}.log \
--region ${REGION} || true
EOF

sudo chmod +x /usr/local/bin/upload-bot-log.sh

# ==========================================================
# LOG UPLOAD SERVICE
# ==========================================================
sudo tee /etc/systemd/system/upload-bot-log.service > /dev/null <<EOF
[Unit]
Description=Upload Bot Log

[Service]
Type=oneshot
ExecStart=/usr/local/bin/upload-bot-log.sh
EOF

sudo tee /etc/systemd/system/upload-bot-log.timer > /dev/null <<EOF
[Unit]
Description=Upload Bot Log Every 5 Minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ==========================================================
# BOT SERVICE
# ==========================================================
sudo tee /etc/systemd/system/${APP_NAME}.service > /dev/null <<EOF
[Unit]
Description=Marketsmith Trading Bot
After=network-online.target

[Service]
User=${APP_USER}
WorkingDirectory=${APP_HOME}/${REPO_NAME}

Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=${APP_HOME}/${REPO_NAME}
Environment=PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_PATH}

ExecStart=${APP_HOME}/${REPO_NAME}/venv/bin/python main.py

Restart=always
RestartSec=10

StandardOutput=append:${LOGFILE}
StandardError=append:${LOGFILE}

ExecStopPost=/usr/local/bin/upload-bot-log.sh

[Install]
WantedBy=multi-user.target
EOF

# ==========================================================
# START SERVICES
# ==========================================================
sudo systemctl daemon-reload

sudo systemctl enable upload-bot-log.timer
sudo systemctl start upload-bot-log.timer

sudo systemctl enable ${APP_NAME}
sudo systemctl restart ${APP_NAME}

sleep 5

sudo systemctl status ${APP_NAME} --no-pager || true

echo "======================================="
echo "BOOTSTRAP COMPLETE"
echo "======================================="