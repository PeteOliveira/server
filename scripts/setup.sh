#!/bin/sh

# Try to load in some environment
source ./env.sh

# Helpers

is_file() {
  local file=$1

  [[ -f $file ]]
}

is_dir() {
  local dir=$1

  [[ -d $dir ]]
}

is_user() {
  local user=$1
  getent passwd "$user" 2>/dev/null

  [ $? -eq 0 ]
}

is_group() {
  local group=$1
  getent group "$group" 2>/dev/null

  [ $? -eq 0 ]
}

contains() {
  local file=$1
  local value=$2

  grep -q "$value" "$file"
  [ $? -eq 0 ]
}

# Main setup functions

setup_root_user() {
  echo "root:$ROOTPASSWORD" | chpasswd
}

setup_deploy_user() {
  is_user "deploy" && return


  useradd -D -s /bin/bash
  useradd deploy --shell /bin/bash
  mkdir /home/deploy
  mkdir /home/deploy/.ssh
  chmod 700 /home/deploy/.ssh
  cp /home/root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys

  echo "deploy:$DEPLOYPASSWORD" | chpasswd

  usermod -a -G sudo deploy
  usermod -a -G ssh-user deploy
}

setup_automatic_updates() {
  contains /etc/apt/apt.conf.d/10periodic "Unattended-Upgrade" && return


  apt-get -y update
  apt-get -y upgrade
  apt-get -y install unattended-upgrades

  cp ${HOME}/server/templates/etc/apt/apt.conf.d/10periodic /etc/apt/apt.conf.d/10periodic
}

setup_ssh() {
  is_group "ssh-user" && return


  groupadd ssh-user

  cp ${HOME}/server/templates/etc/ssh/sshd_config /etc/ssh/sshd_config
  awk '$5 > 2000' /etc/ssh/moduli > "${HOME}/moduli"
  wc -l "${HOME}/moduli" # make sure there is something left
  mv "${HOME}/moduli" /etc/ssh/moduli

  cp ${HOME}/server/templates/etc/issue.net /etc/issue.net

  cd /etc/ssh
  rm ssh_host_*key*
  ssh-keygen -t ed25519 -f ssh_host_ed25519_key < /dev/null
  ssh-keygen -t rsa -b 4096 -f ssh_host_rsa_key < /dev/null
  cd ${HOME}

  service ssh restart
}

setup_firewall() {
  ufw default deny incoming
  ufw allow 22
  ufw allow 443
  ufw allow 80
  ufw allow 25
  ufw enable
}

setup_mail_aliases() {
  contains /etc/aliases "ops" && return


  echo "root: $ROOT_EMAIL" >> /etc/aliases
  echo "ops: $OPS_EMAIL" >> /etc/aliases

  newaliases
}

setup_mail_opendkim() {
  is_file /etc/opendkim.conf && return


  apt-get install -y --force-yes opendkim opendkim-tools

  cat ${HOME}/server/templates/etc/opendkim.conf >> /etc/opendkim.conf

  # Setup the default opendkim socket
  echo "SOCKET="inet:12301@localhost"" >> /etc/default/opendkim

  # Add the milter settings to postfix
  cp ${HOME}/server/templates/etc/postfix/main.cf /etc/postfix/main.cf

  # Trusted Hosts
  cp ${HOME}/server/templates/etc/opendkim/TrustedHosts /etc/opendkim/TrustedHosts
  echo "$WILDCARD_DOMAIN" >> /etc/opendkim/TrustedHosts

  # Key Table
  echo "mail._domainkey.$DOMAIN $DOMAIN:mail:/etc/opendkim/keys/$DOMAIN/mail.private" >> /etc/opendkim/KeyTable

  # Signing Table
  echo "*@$DOMAIN mail._domainkey.$DOMAIN" >> /etc/opendkim/SigningTable

  mkdir -p /etc/opendkim/keys/$DOMAIN
  cd /etc/opendkim/keys/$DOMAIN
  opendkim-genkey -s mail -d $DOMAIN
  chown opendkim:opendkim mail.private
  echo "Copy the p value and create a TXT DNS entry"
  cat mail.txt
  echo 'TXT mail._domainkey "v=DKIM1; k=rsa; p=YOUR_P_VALUE_HERE"'
  cd ${HOME}

  service postfix restart
  service opendkim restart
}

setup_mail_forwarding() {
  contains /etc/postfix/main.cf "virtual_alias_domains" && return


  echo "virtual_alias_domains = $DOMAIN" >> /etc/postfix/main.cf
  echo "virtual_alias_maps = hash:/etc/postfix/virtual" >> /etc/postfix/main.cf

  echo "@$DOMAIN   $VIRTUAL_EMAIL " >> /etc/postfix/virtual

  postmap /etc/postfix/virtual
  service postfix reload
}

setup_mail() {
  is_file /etc/postfix/main.cf && return


  debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME"
  debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
  DEBIAN_FRONTEND=noninteractive apt-get -y install postfix
  apt-get -y install mailutils

  # sed -e 's/inet_interfaces = all/inet_interfaces = localhost/g' /etc/postfix/main.cf > /etc/postfix/main.cf.bak && mv /etc/postfix/main.cf.bak /etc/postfix/main.cf
  service postfix restart

  setup_mail_aliases
  setup_mail_opendkim
  setup_mail_forwarding
}

setup_logwatch() {
  is_dir /var/cache/logwatch && return


  apt-get -y --force-yes install logwatch
  mkdir /var/cache/logwatch
  cp /usr/share/logwatch/default.conf/logwatch.conf /etc/logwatch/conf/
  sed -e "s/--output mail/--mailto $OPS_EMAIL/g" /etc/cron.daily/00logwatch > /etc/cron.daily/00logwatch.bak && mv /etc/cron.daily/00logwatch.bak /etc/cron.daily/00logwatch
}

setup_fail2ban() {
  is_file /etc/fail2ban/jail.local && return

  apt-get -y --force-yes install fail2ban
  cp ${HOME}/server/templates/etc/fail2ban/jail.local /etc/fail2ban/jail.local
  sed -e "s/destemail =/destemail = $OPS_EMAIL/g" /etc/fail2ban/jail.local > /etc/fail2ban/jail.local.bak && mv /etc/fail2ban/jail.local.bak /etc/fail2ban/jail.local
}

setup_rootkits() {
  apt-get -y --force-yes install lynis
  apt-get -y --force-yes install rkhunter
}

setup_swap() {
  is_file /swapfile && return


  dd if=/dev/zero of=/swapfile bs=1MB count=4096
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  echo "/swapfile   none    swap    sw    0   0" >> /etc/fstab

  echo "vm.swappiness=10" >> /etc/sysctl.conf
  echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
}

setup() {
  setup_automatic_updates
  setup_root_user
  setup_deploy_user
  setup_ssh
  setup_fail2ban
  setup_firewall
  setup_rootkits
  setup_logwatch
  setup_swap
  setup_mail
  setup_mail_aliases
  setup_mail_opendkim
  setup_mail_forwarding
}

# Kick it.
setup
