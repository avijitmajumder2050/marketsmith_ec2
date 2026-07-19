#!/bin/bash
set -e

# ==========================================================
# CONFIG
# ==========================================================
REGION="ap-south-1"

APP_USER="ec2-user"
APP_HOME="/home/ec2-user"

GITHUB_REPO="https://github.com/avijitmajumder2050/marketsmith_ec2.git"
REPO_NAME="marketsmith_ec2"

APP_NAME="marketsmithindia-bot"

S3_BUCKET="dhan-trading-data"
S3_PREFIX="trading-bot"

LOGFILE="/var/log/${APP_NAME}.log"
BOOTLOG="/var/log/${APP_NAME}-bootstrap.log"

PLAYWRIGHT_PATH="${APP_HOME}/playwright-browsers"

exec > >(tee -a ${BOOTLOG}) 2>&1

echo "======================================="
echo "BOOTSTRAP STARTED"
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

if [ -d "${REPO_NAME}" ]; then
    rm -rf ${REPO_NAME}
fi

git clone ${GITHUB_REPO}

chown -R ${APP_USER}:${APP_USER} ${REPO_NAME}

cd ${REPO_NAME}

# ==========================================================
# PYTHON VENV
# ==========================================================
python3 -m venv venv

source venv/bin/activate

pip install --upgrade pip setuptools wheel

# ==========================================================
# INSTALL LIBRARIES
# ==========================================================
pip install \
playwright \
requests \
pandas \
boto3 \
beautifulsoup4

# ==========================================================
# REQUIREMENTS
# ==========================================================
if [ -f requirements.txt ]; then
    pip install -r requirements.txt
fi

# ==========================================================
# PLAYWRIGHT INSTALL
# ==========================================================
mkdir -p ${PLAYWRIGHT_PATH}

export PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_PATH}

python -m playwright install chromium

echo "Playwright installation completed"

# ==========================================================
# LOG FILE
# ==========================================================
touch ${LOGFILE}
chmod 666 ${LOGFILE}

# ==========================================================
# RUN BOT ONCE
# ==========================================================
echo "======================================="
echo "STARTING BOT"
echo "======================================="

cd ${APP_HOME}/${REPO_NAME}

export PYTHONPATH=${APP_HOME}/${REPO_NAME}
export PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_PATH}

set +e

${APP_HOME}/${REPO_NAME}/venv/bin/python main.py \
    >> ${LOGFILE} 2>&1

BOT_EXIT_CODE=$?

set -e

echo "======================================="
echo "BOT FINISHED"
echo "EXIT CODE = ${BOT_EXIT_CODE}"
echo "======================================="

# ==========================================================
# UPLOAD LOGS TO S3
# ==========================================================
echo "Uploading logs..."

aws s3 cp \
${LOGFILE} \
s3://${S3_BUCKET}/${S3_PREFIX}/logs/${APP_NAME}.log \
--region ${REGION} || true

aws s3 cp \
${BOOTLOG} \
s3://${S3_BUCKET}/${S3_PREFIX}/logs/${APP_NAME}-bootstrap.log \
--region ${REGION} || true

echo "Logs uploaded"

# ==========================================================
# WAIT FOR S3
# ==========================================================
sleep 30

# ==========================================================
# TERMINATE EC2
# ==========================================================
TOKEN=$(curl -s -X PUT \
"http://169.254.169.254/latest/api/token" \
-H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s \
-H "X-aws-ec2-metadata-token: ${TOKEN}" \
http://169.254.169.254/latest/meta-data/instance-id)

echo "Terminating instance ${INSTANCE_ID}"

aws ec2 terminate-instances \
    --instance-ids ${INSTANCE_ID} \
    --region ${REGION}

echo "Termination request submitted"

echo "======================================="
echo "BOOTSTRAP COMPLETE"
echo "======================================="