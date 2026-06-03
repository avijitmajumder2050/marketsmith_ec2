#!/bin/bash
set -e

# ==========================================================
# CONFIG
# ==========================================================
REGION="ap-south-1"
APP_USER="ec2-user"
APP_HOME="/home/ec2-user"

GITHUB_REPO="https://github.com/YOUR_USERNAME/YOUR_REPO.git"

APP_NAME="marketsmithindia-bot"

S3_BUCKET="s3://dhan-trading-data"
S3_PREFIX="trading-bot"

LOGFILE="/var/log/${APP_NAME}.log"
BOOTLOG="/var/log/${APP_NAME}-bootstrap.log"

exec > >(tee -a ${BOOTLOG}) 2>&1

echo "======================================="
echo "Starting EC2 Bootstrap"
echo "======================================="

# ==========================================================
# OS UPDATE
# ==========================================================
yum update -y

timedatectl set-timezone Asia/Kolkata

# ==========================================================
# INSTALL PACKAGES
# ==========================================================
yum install -y \
python3 \
python3-pip \
git \
awscli

echo "Packages installed"

# ==========================================================
# UPGRADE PIP
# ==========================================================
python3 -m pip install --upgrade pip

# ==========================================================
# PLAYWRIGHT DEPENDENCIES
# ==========================================================
yum install -y \
atk \
cups-libs \
gtk3 \
libXcomposite \
libXcursor \
libXdamage \
libXext \
libXi \
libXrandr \
libXrender \
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

chown -R ${APP_USER}:${APP_USER} ${REPO_NAME}

cd ${REPO_NAME}

# ==========================================================
# PYTHON VENV
# ==========================================================
python3 -m venv venv

source venv/bin/activate

pip install --upgrade pip

# ==========================================================
# PYTHON LIBRARIES
# ==========================================================
pip install \
playwright \
requests \
pandas \
boto3 \
beautifulsoup4

# ==========================================================
# INSTALL CHROMIUM
# ==========================================================
python -m playwright install chromium

# ==========================================================
# REQUIREMENTS.TXT
# ==========================================================
if [ -f requirements.txt ]; then
    pip install -r requirements.txt
fi

# ==========================================================
# LOG FILE
# ==========================================================
touch ${LOGFILE}
chown ${APP_USER}:${APP_USER} ${LOGFILE}
chmod 664 ${LOGFILE}

# ==========================================================
# S3 LOG UPLOAD SCRIPT
# ==========================================================
cat >/usr/local/bin/upload-bot-log.sh <<EOF
#!/bin/bash

aws s3 cp \
${LOGFILE} \
${S3_BUCKET}/${S3_PREFIX}/logs/${APP_NAME}.log \
--region ${REGION} || true
EOF

chmod +x /usr/local/bin/upload-bot-log.sh

# ==========================================================
# SYSTEMD TIMER
# ==========================================================
cat >/etc/systemd/system/upload-bot-log.service <<EOF
[Unit]
Description=Upload Bot Log

[Service]
Type=oneshot
ExecStart=/usr/local/bin/upload-bot-log.sh
EOF

cat >/etc/systemd/system/upload-bot-log.timer <<EOF
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
cat >/etc/systemd/system/${APP_NAME}.service <<EOF
[Unit]
Description=Trading Bot
After=network-online.target

[Service]
User=${APP_USER}
WorkingDirectory=${APP_HOME}/${REPO_NAME}

Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=${APP_HOME}/${REPO_NAME}

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
# ENABLE SERVICES
# ==========================================================
systemctl daemon-reload

systemctl enable upload-bot-log.timer
systemctl start upload-bot-log.timer

systemctl enable ${APP_NAME}
systemctl restart ${APP_NAME}

echo "======================================="
echo "BOOTSTRAP COMPLETE"
echo "======================================="