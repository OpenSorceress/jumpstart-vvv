#!/bin/bash
#
# provision.sh
#
# This file is specified in Vagrantfile and is loaded by Vagrant as the primary
# provisioning script whenever the commands `vagrant up`, `vagrant provision`,
# or `vagrant reload` are used. It provides all of the default packages and
# configurations included with Varying Vagrant Vagrants.



# By storing the date now, we can calculate the duration of provisioning at the
# end of this script.
start_seconds="$(date +%s)"

# Network Detection
#
# Make an HTTP request to google.com to determine if outside access is available
# to us. If 3 attempts with a timeout of 5 seconds are not successful, then we'll
# skip a few things further in provisioning rather than create a bunch of errors.
if [[ "$(wget --tries=3 --timeout=5 --spider http://google.com 2>&1 | grep 'connected')" ]]; then
	echo "Network connection detected..."
	ping_result="Connected"
else
	echo "Network connection not detected. Unable to reach google.com..."
	ping_result="Not Connected"
fi

# PACKAGE INSTALLATION
#
# Build a bash array to pass all of the packages we want to install to a single
# apt-get command. This avoids doing all the leg work each time a package is
# set to install. It also allows us to easily comment out or add single
# packages. We set the array as empty to begin with so that we can append
# individual packages to it as required.
apt_package_install_list=()

# Start with a bash array containing all packages we want to install in the
# virtual machine. We'll then loop through each of these and check individual
# status before adding them to the apt_package_install_list array.
apt_package_check_list=(

	# PHP5
	#
	# Our base packages for php5. As long as php5-fpm and php5-cli are
	# installed, there is no need to install the general php5 package, which
	# can sometimes install apache as a requirement.
	php5-fpm
	php5-cli

	# Common and dev packages for php
	php5-common
	php5-dev

	# Extra PHP modules that we find useful
	php5-memcache
	php5-imagick
	php5-mcrypt
	php5-mysql
	php5-imap
	php5-curl
	php-pear
	php5-gd

	# nginx is installed as the default web server
	nginx

	# memcached is made available for object caching
	memcached

	# mysql is the default database
	mysql-server

	# other packages that come in handy
	imagemagick
	zip
	unzip
	ngrep
	curl
	make
	colordiff
	postfix

	# ntp service to keep clock current
	ntp

	# Req'd for i18n tools
	gettext

	# dos2unix
	# Allows conversion of DOS style line endings to something we'll have less
	# trouble with in Linux.
	dos2unix

	# nodejs for use by grunt
	g++
	nodejs
)

echo "Check for apt packages to install..."

# Loop through each of our packages that should be installed on the system. If
# not yet installed, it should be added to the array of packages to install.
for pkg in "${apt_package_check_list[@]}"; do
	package_version="$(dpkg -s $pkg 2>&1 | grep 'Version:' | cut -d " " -f 2)"
	if [[ -n "${package_version}" ]]; then
		space_count="$(expr 20 - "${#pkg}")" #11
		pack_space_count="$(expr 30 - "${#package_version}")"
		real_space="$(expr ${space_count} + ${pack_space_count} + ${#package_version})"
		printf " * $pkg %${real_space}.${#package_version}s ${package_version}\n"
	else
		echo " *" $pkg [not installed]
		apt_package_install_list+=($pkg)
	fi
done

# MySQL
#
# Use debconf-set-selections to specify the default password for the root MySQL
# account. This runs on every provision, even if MySQL has been installed. If
# MySQL is already installed, it will not affect anything.
echo mysql-server mysql-server/root_password password root | debconf-set-selections
echo mysql-server mysql-server/root_password_again password root | debconf-set-selections

# Postfix
#
# Use debconf-set-selections to specify the selections in the postfix setup. Set
# up as an 'Internet Site' with the host name 'vvv'. Note that if your current
# Internet connection does not allow communication over port 25, you will not be
# able to send mail, even with postfix installed.
echo postfix postfix/main_mailer_type select Internet Site | debconf-set-selections
echo postfix postfix/mailname string vvv | debconf-set-selections
# Disable ipv6 as some ISPs/mail servers have problems with it
echo "inet_protocols = ipv4" >> /etc/postfix/main.cf

# Provide our custom apt sources before running `apt-get update`
ln -sf /srv/config/apt-source-append.list /etc/apt/sources.list.d/vvv-sources.list
echo "Linked custom apt sources"

if [[ $ping_result == "Connected" ]]; then
	# If there are any packages to be installed in the apt_package_list array,
	# then we'll run `apt-get update` and then `apt-get install` to proceed.
	if [[ ${#apt_package_install_list[@]} = 0 ]]; then
		echo -e "No apt packages to install.\n"
	else
		# Before running `apt-get update`, we should add the public keys for
		# the packages that we are installing from non standard sources via
		# our appended apt source.list

		# Retrieve the Nginx signing key from nginx.org
		echo "Applying Nginx signing key..."
		wget --quiet http://nginx.org/keys/nginx_signing.key -O- | apt-key add -

		# Apply the nodejs assigning key
		echo "Applying nodejs signing key..."
		apt-key adv --quiet --keyserver hkp://keyserver.ubuntu.com:80 --recv-key C7917B12 2>&1 | grep "gpg:"
		apt-key export C7917B12 | apt-key add -

		# update all of the package references before installing anything
		echo "Running apt-get update..."
		apt-get update --assume-yes

		# install required packages
		echo "Installing apt-get packages..."
		apt-get install --assume-yes ${apt_package_install_list[@]}

		# Clean up apt caches
		apt-get clean
	fi

	# npm
	#
	# Make sure we have the latest npm version and the update checker module
	npm install -g npm
	npm install -g npm-check-updates

	# ack-grep
	#
	# Install ack-rep directory from the version hosted at beyondgrep.com as the
	# PPAs for Ubuntu Precise are not available yet.
	if [[ -f /usr/bin/ack ]]; then
		echo "ack-grep already installed"
	else
		echo "Installing ack-grep as ack"
		curl -s http://beyondgrep.com/ack-2.04-single-file > /usr/bin/ack && chmod +x /usr/bin/ack
	fi
else
	echo -e "\nNo network connection available, skipping package installation"
fi

# Configuration for nginx
if [[ ! -e /etc/nginx/server.key ]]; then
	echo "Generate Nginx server private key..."
	vvvgenrsa="$(openssl genrsa -out /etc/nginx/server.key 2048 2>&1)"
	echo "$vvvgenrsa"
fi
if [[ ! -e /etc/nginx/server.csr ]]; then
	echo "Generate Certificate Signing Request (CSR)..."
	openssl req -new -batch -key /etc/nginx/server.key -out /etc/nginx/server.csr
fi
if [[ ! -e /etc/nginx/server.crt ]]; then
	echo "Sign the certificate using the above private key and CSR..."
	vvvsigncert="$(openssl x509 -req -days 365 -in /etc/nginx/server.csr -signkey /etc/nginx/server.key -out /etc/nginx/server.crt 2>&1)"
	echo "$vvvsigncert"
fi

echo -e "\nSetup configuration files..."

# Used to to ensure proper services are started on `vagrant up`
cp /srv/config/init/vvv-start.conf /etc/init/vvv-start.conf

echo " * Copied /srv/config/init/vvv-start.conf               to /etc/init/vvv-start.conf"

# Copy nginx configuration from local
cp /srv/config/nginx-config/nginx.conf /etc/nginx/nginx.conf
cp /srv/config/nginx-config/nginx-wp-common.conf /etc/nginx/nginx-wp-common.conf
if [[ ! -d /etc/nginx/custom-sites ]]; then
	mkdir /etc/nginx/custom-sites/
fi
rsync -rvzh --delete /srv/config/nginx-config/sites/ /etc/nginx/custom-sites/

echo " * Copied /srv/config/nginx-config/nginx.conf           to /etc/nginx/nginx.conf"
echo " * Copied /srv/config/nginx-config/nginx-wp-common.conf to /etc/nginx/nginx-wp-common.conf"
echo " * Rsync'd /srv/config/nginx-config/sites/              to /etc/nginx/custom-sites"

# Copy php-fpm configuration from local
cp /srv/config/php5-fpm-config/php5-fpm.conf /etc/php5/fpm/php5-fpm.conf
cp /srv/config/php5-fpm-config/www.conf /etc/php5/fpm/pool.d/www.conf
cp /srv/config/php5-fpm-config/php-custom.ini /etc/php5/fpm/conf.d/php-custom.ini

echo " * Copied /srv/config/php5-fpm-config/php5-fpm.conf     to /etc/php5/fpm/php5-fpm.conf"
echo " * Copied /srv/config/php5-fpm-config/www.conf          to /etc/php5/fpm/pool.d/www.conf"
echo " * Copied /srv/config/php5-fpm-config/php-custom.ini    to /etc/php5/fpm/conf.d/php-custom.ini"

# Copy custom dotfiles and bin file for the vagrant user from local
cp /srv/config/bash_profile /home/vagrant/.bash_profile
cp /srv/config/bash_aliases /home/vagrant/.bash_aliases
rsync -rvzh --delete /srv/config/homebin/ /home/vagrant/bin/

echo " * Copied /srv/config/bash_profile                      to /home/vagrant/.bash_profile"
echo " * Copied /srv/config/bash_aliases                      to /home/vagrant/.bash_aliases"
echo " * rsync'd /srv/config/homebin                          to /home/vagrant/bin"

# RESTART SERVICES
#
# Make sure the services we expect to be running are running.
echo -e "\nRestart services..."
service nginx restart

# Enable PHP mcrypt module by default
php5enmod mcrypt

service php5-fpm restart

# If MySQL is installed, go through the various imports and service tasks.
exists_mysql="$(service mysql status)"
if [[ "mysql: unrecognized service" != "${exists_mysql}" ]]; then
	echo -e "\nSetup MySQL configuration file links..."

	# Copy mysql configuration from local
	cp /srv/config/mysql-config/my.cnf /etc/mysql/my.cnf
	cp /srv/config/mysql-config/root-my.cnf /home/vagrant/.my.cnf

	echo " * Copied /srv/config/mysql-config/my.cnf               to /etc/mysql/my.cnf"
	echo " * Copied /srv/config/mysql-config/root-my.cnf          to /home/vagrant/.my.cnf"

	# MySQL gives us an error if we restart a non running service, which
	# happens after a `vagrant halt`. Check to see if it's running before
	# deciding whether to start or restart.
	if [[ "mysql stop/waiting" == "${exists_mysql}" ]]; then
		echo "service mysql start"
		service mysql start
	else
		echo "service mysql restart"
		service mysql restart
	fi

	# IMPORT SQL
	#
	# Create the databases (unique to system) that will be imported with
	# the mysqldump files located in database/backups/
	if [[ -f /srv/database/init-custom.sql ]]; then
		mysql -u root -proot < /srv/database/init-custom.sql
		echo -e "\nInitial custom MySQL scripting..."
	else
		echo -e "\nNo custom MySQL scripting found in database/init-custom.sql, skipping..."
	fi

	# Setup MySQL by importing an init file that creates necessary
	# users and databases that our vagrant setup relies on.
	mysql -u root -proot < /srv/database/init.sql
	echo "Initial MySQL prep..."

	# Process each mysqldump SQL file in database/backups to import
	# an initial data set for MySQL.
	/srv/database/import-sql.sh
else
	echo -e "\nMySQL is not installed. No databases imported."
fi

# Run wp-cli, tar, and npm as `vagrant` user instead of `root`
if (( $EUID == 0 )); then
    wp() { sudo -EH -u vagrant -- wp "$@"; }
    tar() { sudo -EH -u vagrant -- tar "$@"; }
    npm() { sudo -EH -u vagrant -- npm "$@"; }
fi

# If we are connected to the Internet, download wp-cli and phpMyAdmin.
if [[ $ping_result == "Connected" ]]; then
	# WP-CLI Install
    echo -e "\nDownloading wp-cli, see http://wp-cli.org"
    cd /home/vagrant
    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    sudo mv wp-cli.phar /usr/local/bin/wp

	# Download phpMyAdmin
	if [[ ! -d /srv/www/default/database-admin ]]; then
		echo "Downloading phpMyAdmin 4.2.13.1..."
		cd /srv/www/default
		wget -q -O phpmyadmin.tar.gz 'http://sourceforge.net/projects/phpmyadmin/files/phpMyAdmin/4.2.13.1/phpMyAdmin-4.2.13.1-all-languages.tar.gz/download'
		tar -xf phpmyadmin.tar.gz
		mv phpMyAdmin-4.2.13.1-all-languages database-admin
		rm phpmyadmin.tar.gz
	else
		echo "PHPMyAdmin already installed."
	fi
	cp /srv/config/phpmyadmin-config/config.inc.php /srv/www/default/database-admin/
else
	echo -e "\nNo network available, skipping network installations"
fi

# Find new sites to setup.
# Kill previously symlinked Nginx configs
# We can't know what sites have been removed, so we have to remove all
# the configs and add them back in again.
find /etc/nginx/custom-sites -name 'vvv-auto-*.conf' -exec rm {} \;

# Look for site setup scripts
for SITE_CONFIG_FILE in $(find /srv/www -maxdepth 5 -name 'vvv-init.sh'); do
	DIR="$(dirname $SITE_CONFIG_FILE)"
	(
		cd "$DIR"
		source vvv-init.sh
	)
done

# Look for Nginx vhost files, symlink them into the custom sites dir
for SITE_CONFIG_FILE in $(find /srv/www -maxdepth 5 -name 'vvv-nginx.conf'); do
	DEST_CONFIG_FILE=${SITE_CONFIG_FILE//\/srv\/www\//}
	DEST_CONFIG_FILE=${DEST_CONFIG_FILE//\//\-}
	DEST_CONFIG_FILE=${DEST_CONFIG_FILE/%-vvv-nginx.conf/}
	DEST_CONFIG_FILE="vvv-auto-$DEST_CONFIG_FILE-$(md5sum <<< "$SITE_CONFIG_FILE" | cut -c1-32).conf"
	# We allow the replacement of the {vvv_path_to_folder} token with
	# whatever you want, allowing flexible placement of the site folder
	# while still having an Nginx config which works.
	DIR="$(dirname $SITE_CONFIG_FILE)"
	sed "s#{vvv_path_to_folder}#$DIR#" "$SITE_CONFIG_FILE" > /etc/nginx/custom-sites/"$DEST_CONFIG_FILE"
done

# Parse any vvv-hosts file located in www/ or subdirectories of www/
# for domains to be added to the virtual machine's host file so that it is
# self aware.
#
# Domains should be entered on new lines.
echo "Cleaning the virtual machine's /etc/hosts file..."
sed -n '/# vvv-auto$/!p' /etc/hosts > /tmp/hosts
mv /tmp/hosts /etc/hosts
echo "Adding domains to the virtual machine's /etc/hosts file..."
find /srv/www/ -maxdepth 5 -name 'vvv-hosts' | \
while read hostfile; do
	while IFS='' read -r line || [ -n "$line" ]; do
		if [[ "#" != ${line:0:1} ]]; then
			if [[ -z "$(grep -q "^127.0.0.1 $line$" /etc/hosts)" ]]; then
				echo "127.0.0.1 $line # vvv-auto" >> /etc/hosts
				echo " * Added $line from $hostfile"
			fi
		fi
	done < "$hostfile"
done

end_seconds="$(date +%s)"
echo ""
echo "######################################################"
echo "#"
echo "# Provisioning complete in "$(expr $end_seconds - $start_seconds)" seconds"
if [[ $ping_result == "Connected" ]]; then
	echo "# External network connection established, packages up to date."
else
	echo "# No external network available. Package installation and maintenance skipped."
fi
echo "# Visit the dashboard             http://vvv.dev"
echo "# Visit the site                  jumpstart.dev"
echo "#"
echo "######################################################"
echo ""