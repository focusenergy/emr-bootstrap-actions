#/usr/bin/perl

eval 'exec /usr/bin/perl -w -S $0 ${1+"$@"}'
if 0; # not running under some shell

# AWS EMR bootstrap script
# for installing open-source R (www.r-project.org) with RHadoop packages and RStudio on AWS EMR
#
# tested with AMI 3.2.1 (hadoop 2.4.0)
#
# schmidbe@amazon.de
# 24. September 2014
##############################


# Usage:
# --rstudio - installs rstudio-server default false
# --rhdfs - installs rhdfs package, default false
# --plyrmr - installs plyrmr package, default false
# --updateR - installs latest R version, default false
# --user - sets user for rstudio, default "rstudio"
# --user-pw - sets user-pw for user USER, default "rstudio"
# --rstudio-port - sets rstudio port, default 80

use strict;
use Getopt::Long;


my $std_packages_s3 = 's3://wl-applied-math-dev/bootstrap/r-packages.tgz';
my @extra_packages = ();

GetOptions('standard-packages!' => \(my $standard_packages = 1),
	   'common_pl' => \(my $common_pl = 's3://wl-applied-math-dev/bootstrap/common.pl'),
	   'extra-packages=s' => \@extra_packages,
	   'rstudio!' => \(my $rstudio = 1),
	   'rstudio-port=i' => \(my $rstudio_port = 8787),
	   'r-site-lib=s' => \(my $r_site_lib = '/usr/local/lib/R/site-library'),
	   'user=s' => \(my $user = 'rstudio'),
	   'userpw=s' => \(my $userpw = 'rstudio'),
	   'rmr2!' => \(my $rmr2 = 0),
	   'plyrmr2!' => \(my $plyrmr2 = 0),
	   'rhdfs!' => \(my $rhdfs = 0),
	   'updateR!' => \(my $updateR = 0),
	   );
@extra_packages = split /,/, join ',', @extra_packages;

if ($common_pl) {
  system(qw(aws s3 cp), $common_pl, 'common.pl');
  require('common.pl');
}


# check for master node
my $is_master = 1;
if (-e '/mnt/var/lib/info/instance.json') {
  $is_master = (`cat /mnt/var/lib/info/instance.json` =~ /"isMaster":\s*true/);
}


# install latest R version from AWS Repo
sudo(qw(yum install -y R));
sudo(qw(mkdir -p), $r_site_lib);

# create rstudio user on all machines
# we need a unix user with home directory and password and hadoop permission
sudo('adduser', $user);
do_system(qq{echo "$user:$userpw" | sudo chpasswd});
sudo(qw(chown -R), $user, $r_site_lib);

# ensure the rstudio user has write permissions for hadoop scratch space
sudo(qw(usermod -a -G hadoop), $user);

# install rstudio
# only run if master node
if ($is_master && $rstudio) {
  # please check and update for latest RStudio version
  # install Rstudio server

  # needed on Amazon Linux to make RStudio Server talk to OpenSSL
  sudo(qw(ln -s /lib64/libcrypto.so.10 /lib64/libcrypto.so.6));
  sudo(qw(ln -s /usr/lib64/libssl.so.10 /lib64/libssl.so.6));

  my $rstudio_url = 'https://download2.rstudio.org/rstudio-server-rhel-1.0.136-x86_64.rpm';
  do_system(qq{wget $rstudio_url -O rstudio.rpm && sudo yum install -y --nogpgcheck rstudio.rpm && rm rstudio.rpm});

  # change port - 8787 will not work for many companies
  sudo(qq{sh -c 'echo www-port=$rstudio_port >> /etc/rstudio/rserver.conf'});
  sudo(qw(rstudio-server restart));
}

# set unix environment variables
my %hadoop_env = (HADOOP_HOME => '/home/hadoop',
		  HADOOP_CMD => '/home/hadoop/bin/hadoop',
		  HADOOP_STREAMING => '/home/hadoop/contrib/streaming/hadoop-streaming.jar',
		  JAVA_HOME => '/usr/lib/jvm/java');
%ENV = (%ENV, %hadoop_env);
sudo(qq{sh -c "echo 'export $_=$hadoop_env{$_}' >> /etc/profile"}) for keys %hadoop_env;


# fix hadoop tmp permission
sudo(qw{chmod 777 -R /mnt/var/lib/hadoop/tmp});


# RCurl package needs curl-config unix package
sudo(qw{yum install -y curl-devel});


# fix java binding - R and packages have to be compiled with the same java version as hadoop
sudo(qw{R CMD javareconf});


# install required packages
if ($standard_packages) {
  do_system("aws s3 cp $std_packages_s3 /tmp/r-packages.tgz && cd $r_site_lib && sudo tar -zxvf /tmp/r-packages.tgz");
}
ensure_pkg(@extra_packages);

if ($rmr2) {
  ensure_pkg_from_url('rmr2', "https://raw.github.com/RevolutionAnalytics/rmr2/master/build/rmr2_3.1.2.tar.gz");
}

if ($rhdfs) {
  ensure_pkg_from_url('rhdfs', "https://raw.github.com/RevolutionAnalytics/rhdfs/master/build/rhdfs_1.0.8.tar.gz");
}

if ($plyrmr2) {
  ensure_pkg_from_url('plyrmr', "https://raw.github.com/RevolutionAnalytics/plyrmr/master/build/plyrmr_0.3.0.tar.gz");
}
