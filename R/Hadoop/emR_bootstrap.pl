#/usr/bin/perl

eval 'exec sudo /usr/bin/perl -w -S $0 ${1+"$@"}'
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
	   'sparklyr!' => \(my $sparklyr = 0),
	   'rmr2!' => \(my $rmr2 = 0),
	   'plyrmr2!' => \(my $plyrmr2 = 0),
	   'rhdfs!' => \(my $rhdfs = 0),
	   'updateR!' => \(my $updateR = 0),
	   );
@extra_packages = split /[,;:]/, join ',', @extra_packages;

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
do_system(qw(yum install -y R));
do_system(qw(mkdir -p), $r_site_lib);

# create rstudio user on all machines
# we need a unix user with home directory and password and hadoop permission
do_system('adduser', $user);
do_system(qq{echo "$user:$userpw" | chpasswd});

# ensure the rstudio user has write permissions for hadoop scratch space
do_system(qw(usermod -a -G hadoop), $user);

# install rstudio
# only run if master node
if ($is_master && $rstudio) {
  # please check and update for latest RStudio version
  # install Rstudio server

  # needed on Amazon Linux to make RStudio Server talk to OpenSSL
  symlink('/lib64/libcrypto.so.10', '/lib64/libcrypto.so.6');
  symlink('/usr/lib64/libssl.so.10', '/lib64/libssl.so.6');

  my $rstudio_url = 'https://download2.rstudio.org/rstudio-server-rhel-1.0.136-x86_64.rpm';
  do_system(qq{wget $rstudio_url -O rstudio.rpm && yum install -y --nogpgcheck rstudio.rpm && rm rstudio.rpm});

  # change port - 8787 will not work for many companies
  spew(">> /etc/rstudio/rserver.conf", "www-port=$rstudio_port");
  do_system(qw(rstudio-server restart));
}

# set unix environment variables
my %hadoop_env = (HADOOP_HOME => '/home/hadoop',
		  HADOOP_CMD => '/home/hadoop/bin/hadoop',
		  HADOOP_STREAMING => '/home/hadoop/contrib/streaming/hadoop-streaming.jar',
		  JAVA_HOME => '/usr/lib/jvm/java',
		  SPARK_HOME => '/usr/lib/spark');
%ENV = (%ENV, %hadoop_env);
spew(">> /etc/profile", map "export $_=$hadoop_env{$_}", keys %hadoop_env);
spew(">> /usr/lib64/R/etc/Renviron.site", map "$_=$hadoop_env{$_}", keys %hadoop_env);



# fix hadoop tmp permission
do_system(qw{chmod 777 -R /mnt/var/lib/hadoop/tmp});


# RCurl package needs curl-config unix package
do_system(qw{yum install -y curl-devel});


# fix java binding - R and packages have to be compiled with the same java version as hadoop
do_system(qw{R CMD javareconf});


# install required packages
if ($standard_packages) {
  do_system("aws s3 cp $std_packages_s3 /tmp/r-packages.tgz && cd $r_site_lib && tar -zxvf /tmp/r-packages.tgz");
}
ensure_pkg(@extra_packages);

if ($rmr2) {
  ensure_pkg_from_github('RevolutionAnalytics/rmr2');
}

if ($rhdfs) {
  ensure_pkg_from_github('RevolutionAnalytics/rhdfs');
}

if ($plyrmr2) {
  ensure_pkg_from_github('RevolutionAnalytics/plyrmr');
}

if ($sparklyr) {
  # For now, need latest sparklyr bleeding-edge to support Spark 2.1.0.
  ensure_pkg_from_github('RStudio/sparklyr');
}

do_system(qw(yum install -y git));
do_system(qq{wget https://github.com/apache/spark/archive/master.zip && unzip master.zip && cd spark-master/R/pkg && Rscript -e 'devtools::document(); devtools::install()'});

do_system(qw(chown -R), $user, $r_site_lib);
