# Copyright (C) 2008-2014 Zentyal S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

use strict;
use warnings;

package EBox::Samba;

use base qw(EBox::Module::LDAP
            EBox::SysInfo::Observer
            EBox::NetworkObserver
            EBox::FirewallObserver
            EBox::LogObserver
            EBox::SyncFolders::Provider
            EBox::Samba::SyncProvider);

use EBox::Config;
use EBox::Exceptions::External;
use EBox::Exceptions::Internal;
use EBox::Exceptions::InvalidType;
use EBox::Exceptions::LDAP;
use EBox::Exceptions::MissingArgument;
use EBox::Exceptions::UnwillingToPerform;
use EBox::FileSystem;
use EBox::Gettext;
use EBox::Global;
use EBox::Ldap;
use EBox::LDAP::ExternalAD;
use EBox::LdapUserImplementation;
use EBox::Menu::Folder;
use EBox::Menu::Item;
use EBox::SambaLogHelper;
use EBox::Service;
use EBox::Sudo;
use EBox::SyncFolders::Folder;
use EBox::Samba::Computer;
use EBox::Samba::Contact;
use EBox::Samba::Container;
use EBox::Samba::DMD;
use EBox::Samba::GPO;
use EBox::Samba::Group;
use EBox::Samba::LdapObject;
use EBox::Samba::NamingContext;
use EBox::Samba::OU;
use EBox::Samba::Provision;
use EBox::Samba::SecurityPrincipal;
use EBox::Samba::Slave;
use EBox::Samba::SmbClient;
use EBox::Samba::User;
use EBox::UsersSync::Master;
use EBox::UsersSync::Slave;
use EBox::Util::Random qw( generate );
use EBox::Util::Random;
use EBox::Util::Version;
use EBox::CloudSync::Slave;

use Digest::SHA;
use Digest::MD5;
use Sys::Hostname;

use TryCatch::Lite;
use JSON::XS;
use Net::LDAP::Control::Sort;
use Net::LDAP::Util qw(ldap_explode_dn);
use File::Copy;
use File::Slurp;
use File::Basename;
use File::Temp qw/tempfile/;
use Perl6::Junction qw(any);
use String::ShellQuote;
use Fcntl qw(:flock);
use Net::Ping;
use Samba::Security::AccessControlEntry;
use Samba::Security::Descriptor qw(
    DOMAIN_RID_ADMINISTRATOR
    SEC_ACE_FLAG_CONTAINER_INHERIT
    SEC_ACE_FLAG_OBJECT_INHERIT
    SEC_ACE_TYPE_ACCESS_ALLOWED
    SEC_DESC_DACL_AUTO_INHERITED
    SEC_DESC_DACL_PROTECTED
    SEC_DESC_SACL_AUTO_INHERITED
    SEC_FILE_EXECUTE
    SEC_RIGHTS_FILE_ALL
    SEC_RIGHTS_FILE_READ
    SEC_RIGHTS_FILE_WRITE
    SEC_STD_ALL
    SEC_STD_DELETE
    SECINFO_DACL
    SECINFO_GROUP
    SECINFO_OWNER
    SECINFO_PROTECTED_DACL
    SEC_STD_WRITE_OWNER
    SEC_STD_READ_CONTROL
    SEC_STD_WRITE_DAC
    SEC_FILE_READ_ATTRIBUTE
);
use Samba::Smb qw(
    FILE_ATTRIBUTE_NORMAL
    FILE_ATTRIBUTE_ARCHIVE
    FILE_ATTRIBUTE_DIRECTORY
    FILE_ATTRIBUTE_HIDDEN
    FILE_ATTRIBUTE_READONLY
    FILE_ATTRIBUTE_SYSTEM
);
use String::ShellQuote 'shell_quote';
use Time::HiRes;
use IO::Socket::INET;
use IO::Socket::UNIX;


use constant SAMBA_DIR            => '/home/samba/';
use constant SAMBATOOL            => '/usr/bin/samba-tool';
use constant SAMBACONFFILE        => '/etc/samba/smb.conf';
use constant SHARESCONFFILE       => '/etc/samba/shares.conf';
use constant PRIVATE_DIR          => '/var/lib/samba/private/';
use constant SAMBA_DNS_ZONE       => PRIVATE_DIR . 'named.conf';
use constant SAMBA_DNS_POLICY     => PRIVATE_DIR . 'named.conf.update';
use constant SAMBA_DNS_KEYTAB     => PRIVATE_DIR . 'dns.keytab';
use constant SECRETS_KEYTAB       => PRIVATE_DIR . 'secrets.keytab';
use constant SAM_DB               => PRIVATE_DIR . 'sam.ldb';
use constant SAMBA_PRIVILEGED_SOCKET => PRIVATE_DIR . '/ldap_priv';
use constant FSTAB_FILE           => '/etc/fstab';
use constant SYSVOL_DIR           => '/var/lib/samba/sysvol';
use constant PROFILES_DIR         => SAMBA_DIR . 'profiles';
use constant ANTIVIRUS_CONF       => '/var/lib/zentyal/conf/samba-antivirus.conf';
use constant SAMBA_DNS_UPDATE_LIST => PRIVATE_DIR . 'dns_update_list';

use constant COMPUTERSDN    => 'ou=Computers';
use constant AD_COMPUTERSDN => 'cn=Computers';

use constant STANDALONE_MODE      => 'master';
use constant EXTERNAL_AD_MODE     => 'external-ad';
use constant BACKUP_MODE_FILE     => 'LDAP_MODE.bak';
use constant BACKUP_USERS_FILE    => 'userlist.bak';

use constant JOURNAL_DIR    => EBox::Config::home() . 'syncjournal/';
use constant AUTHCONFIGTMPL => '/etc/auth-client-config/profile.d/acc-zentyal';
use constant CRONFILE       => '/etc/cron.d/zentyal-users';
use constant CRONFILE_EXTERNAL_AD_MODE => '/etc/cron.daily/zentyal-users-external-ad';

use constant SAMBACONFFILE        => '/etc/samba/smb.conf';
use constant PRIVATE_DIR          => '/var/lib/samba/private/';
use constant SYSVOL_DIR           => '/var/lib/samba/sysvol';

use constant SHARES_DIR           => SAMBA_DIR . 'shares';
use constant PROFILES_DIR         => SAMBA_DIR . 'profiles';
use constant ANTIVIRUS_CONF       => '/var/lib/zentyal/conf/samba-antivirus.conf';

use constant SAMBA_DNS_UPDATE_LIST => PRIVATE_DIR . 'dns_update_list';

# Kerberos constants
use constant KERBEROS_PORT => 88;
use constant KPASSWD_PORT => 464;
use constant KRB5_CONF_FILE => '/var/lib/samba/private/krb5.conf';
use constant SYSTEM_WIDE_KRB5_CONF_FILE => '/etc/krb5.conf';
use constant SYSTEM_WIDE_KRB5_KEYTAB => '/etc/krb5.keytab';

# SSSD conf
use constant SSSD_CONF_FILE => '/etc/sssd/sssd.conf';

use constant OBJECT_EXISTS => 1;
use constant OBJECT_EXISTS_AND_HIDDEN_SID => 2;


sub _create
{
    my $class = shift;
    my $self = $class->SUPER::_create(name => 'samba',
                                      printableName => __('Domain Controller and File Sharing'),
                                      @_);
    bless($self, $class);
    $self->_setupForMode();

    return $self;
}

# Method: _setupForMode
#
#   setup the internal attributes need for active authentication mode
#
sub _setupForMode
{
    my ($self) = @_;
    my $mode = $self->mode();
    if ($mode ne EXTERNAL_AD_MODE) {
        $self->{ldapClass} = 'EBox::Ldap';
        $self->{ouClass} = 'EBox::Samba::OU';
        $self->{userClass} = 'EBox::Samba::User';
        $self->{contactClass} = 'EBox::Samba::Contact';
        $self->{groupClass} = 'EBox::Samba::Group';
        $self->{containerClass} = 'EBox::Samba::Container';
    } else {
        $self->{ldapClass} = 'EBox::LDAP::ExternalAD';
        $self->{ouClass} = 'EBox::Samba::OU::ExternalAD';
        $self->{userClass} = 'EBox::Samba::User::ExternalAD';
        $self->{contactClass} = 'EBox::Samba::Contact::ExternalAD';
        $self->{groupClass} = 'EBox::Samba::Group::ExternalAD';
        $self->{containerClass} = 'EBox::Samba::Container::ExternalAD';
        # load this classes only when needed
        foreach my $pkg ($self->{ldapClass}, $self->{ouClass}, $self->{userClass}, $self->{contactClass}, $self->{groupClass}, $self->{containerClass}) {
            eval "use $pkg";
            $@ and throw EBox::Exceptions::Internal("When loading $pkg: $@");
        }
    }
}

# Method: ldapClass
#
#   Return the LDAP class implementation to use.
#
sub ldapClass
{
    my ($self) = @_;

    (defined $self->{ldapClass}) or
        throw EBox::Exceptions::Internal("ldapClass not initialized.");

    return $self->{ldapClass};
}

# Method: ouClass
#
#   Return the OU class implementation to use.
#
sub ouClass
{
    my ($self) = @_;

    (defined $self->{ouClass}) or
        throw EBox::Exceptions::Internal("ouClass not initialized.");

    return $self->{ouClass};
}

# Method: userClass
#
#   Return the User class implementation to use.
#
sub userClass
{
    my ($self) = @_;

    (defined $self->{userClass}) or
        throw EBox::Exceptions::Internal("userClass not initialized.");

    return $self->{userClass};
}

# Method: contactClass
#
#   Return the Contact class implementation to use.
#
sub contactClass
{
    my ($self) = @_;

    (defined $self->{contactClass}) or
        throw EBox::Exceptions::Internal("contactClass not initialized.");

    return $self->{contactClass};
}

# Method: groupClass
#
#   Return the Group class implementation to use.
#
sub groupClass
{
    my ($self) = @_;

    (defined $self->{groupClass}) or
        throw EBox::Exceptions::Internal("groupClass not initialized.") ;

    return $self->{groupClass};
}

# Method: container
#
#   Return the Container class implementation to use.
#
#  Warning:
#    this can be undefined since standalone server does not use it
sub containerClass
{
    my ($self) = @_;
    return $self->{containerClass};
}

# Method: actions
#
#       Override EBox::ServiceModule::ServiceInterface::actions
#
sub actions
{
    my ($self) = @_;

    my @actions;

    if ($self->mode() eq STANDALONE_MODE) {
        push (@actions, {
            'action' => __('Your LDAP database will be populated with some basic organizational units'),
            'reason' => __('Zentyal needs this organizational units to add users and groups into them.'),
            'module' => 'samba'
        });
        push (@actions, {
            'action' => __('Create Samba home directory for shares and groups'),
            'reason' => __('Zentyal will create the directories for Samba ' .
                           'shares and groups under /home/samba.'),
            'module' => 'samba',
        });

        # FIXME: This probably won't work if PAM is enabled after enabling the module
        if ($self->model('PAM')->enable_pamValue()) {
            push @actions, {
                    'action' => __('Configure PAM.'),
                    'reason' => __('Zentyal will give LDAP samba system account.'),
                    'module' => 'samba'
                };
        }
    }

    return \@actions;
}

# Method: usedFiles
#
#       Override EBox::Module::Service::files
#
sub usedFiles
{
    my ($self) = @_;
    my @files = ();
    push @files, {
            'file'   => SYSTEM_WIDE_KRB5_CONF_FILE,
            'reason' => __('To set up kerberos authentication'),
            'module' => 'samba'
        };

    if ($self->mode() eq STANDALONE_MODE) {
        push @files, (
            {
                'file' => '/etc/nsswitch.conf',
                'reason' => __('To make NSS use LDAP resolution for user and '.
                               'group accounts. Needed for Samba PDC configuration.'),
                'module' => 'samba'
            },
            {
                'file' => '/etc/fstab',
                'reason' => __('To add quota support to /home partition.'),
                'module' => 'samba'
            },
            {
                'file' => SSSD_CONF_FILE,
                'reason' => __('To configure System Security Services Daemon to manage remote'
                               . ' authentication mechanisms'),
                'module' => 'samba'
            },
            {
                'file'   => FSTAB_FILE,
                'reason' => __('To enable extended attributes and acls.'),
                'module' => 'samba',
            },
        );
    }

    return \@files;
}

# Method: initialSetup
#
# Overrides:
#
#   EBox::Module::Base::initialSetup
#
sub initialSetup
{
    my ($self, $version) = @_;

    # Create default rules and services
    # only if installing the first time
    unless ($version) {
        my $services = EBox::Global->modInstance('services');

        my $serviceName = 'samba';
        unless($services->serviceExists(name => $serviceName)) {
            $services->addMultipleService(
                'name' => $serviceName,
                'printableName' => 'Samba',
                'description' => __('Domain and File sharing protocols'),
                'internal' => 1,
                'readOnly' => 1,
                'services' => $self->_services(),
            );
        }

        my $firewall = EBox::Global->modInstance('firewall');
        $firewall->setInternalService($serviceName, 'accept');
        $firewall->saveConfigRecursive();
    }

    if (defined ($version) and (EBox::Util::Version::compare($version, '3.5') < 0)) {
        $self->_migrateTo35();
    }
}

sub _migrateTo35
{
    my ($self) = @_;

    return unless ($self->configured());


    # set samba conf to allow schemas updates
    $self->_setConf();
    EBox::Service::manage('samba-ad-dc', 'restart');
    $self->_performSetup();
    EBox::Service::manage('samba-ad-dc', 'restart');

    # Set gidNumbers to Domain Users, etc.
    $self->getProvision()->mapAccounts();

    my $ldifFile = '/var/lib/zentyal/conf/upgrade-to-3.5/data.ldif';

    return unless (-f $ldifFile);

    use Net::LDAP::LDIF;
    my $ldif = Net::LDAP::LDIF->new($ldifFile, 'r', onerror => 'undef');

    while (not $ldif->eof()) {
        my $entry = $ldif->read_entry ();
        if ($ldif->error()) {
           EBox::error("Error reading LDIF file $ldifFile: " . $ldif->error() .
                       '. Error lines: ' .  $ldif->error_lines());
        } else {
            my $gidNumber = $entry->get_value('gidNumber');
            my $uid = $entry->get_value('uid');
            if ($uid) {
                my $uidNumber = $entry->get_value('uidNumber');
                if ($uidNumber) {
                    my $user = new EBox::Samba::User(samAccountName => $uid);
                    next unless $user->exists();

                    $user->set('uidNumber', $uidNumber);
                    unless ($user->hasValue('objectClass', 'systemQuotas')) {
                        my @objectclass = $user->get('objectClass');
                        push (@objectclass, 'systemQuotas');
                        $user->set('objectClass', \@objectclass);
                    }

                    $user->set('gidNumber', $gidNumber, 1) if (defined $gidNumber);
                    for my $attr (qw(quota loginShell homeDirectory)) {
                        my $value = $entry->get_value($attr);
                        $user->set($attr, $value, 1) if defined ($value);
                    }
                    $user->save();
                }
            } elsif (defined $gidNumber) {
                my $cn = $entry->get_value('cn');
                if ($cn) {
                    my $group = new EBox::Samba::Group(samAccountName => $cn);
                    next unless $group->exists();

                    my $oldGidNumber = $group->get('gidNumber');
                    if ((not defined $oldGidNumber) or ($gidNumber != $oldGidNumber)) {
                        $group->set('gidNumber', $gidNumber, 1);
                    }

                    my @objectClass = $entry->get_value('objectClass');
                    my $isSecurity = grep  { $_ eq 'posixGroup' } @objectClass;

                    $group->setSecurityGroup($isSecurity, 1);
                    $group->save();
                }
            }
        }
    }
    $ldif->done();

    $self->getProvision()->mapAccounts();
}

sub _checkEnableIPs
{
    my ($self) = @_;
    my $network = $self->global()->modInstance('network');
    my @dhcpIfaces = ();
    my $noAddresses = 1;
    foreach my $iface (@{ $network->allIfaces() }) {
        my @addresses = @{ $network->ifaceAddresses($iface) };
        if (@addresses) {
            $noAddresses = 0;
            last;
        }
        if ($network->ifaceMethod($iface) eq 'dhcp') {
            push @dhcpIfaces, $iface;
        }
    }
    if ($noAddresses) {
        my $errMsg;
        if (@dhcpIfaces) {
            $errMsg = __x('Cannot enable Users and Computers module because your system does not have availalbe IPs. Since you have dhcp interfaces ({ifaces}) it is possible that you have not received leases. Saving changes if network module has just been configured or waiting for a lease can solve this situation',
                          ifaces => "@dhcpIfaces"
                         );
        } else {
            $errMsg = __x('Cannot enable Users and Computers module because your system does not have available IPs. {oh}Configuring network interfaces{ch} and saving changes can solve this situation',
                          oh => '<a href="/Network/Ifaces">',
                          ch => '</a>'
                          );
        }

        EBox::Exceptions::External->throw($errMsg);
    }
}

sub setupDNS
{
    my ($self) = @_;

    EBox::info("Setting up DNS");

    # Get the host domain
    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $ownDomain = $sysinfo->hostDomain();
    my $hostName = $sysinfo->hostName();

    # Create the domain in the DNS module if it does not exists
    my $dnsMod = EBox::Global->modInstance('dns');
    my $domainModel = $dnsMod->model('DomainTable');
    my $row = $domainModel->find(domain => $ownDomain);
    if (defined $row) {
        # Set the domain as managed and readonly
        $row->setReadOnly(1);
        $row->elementByName('managed')->setValue(1);
        $row->store();
    } else {
        $domainModel->addRow(domain => $ownDomain, managed => 1, readOnly => 1);
    }

    EBox::debug("Adding DNS records for kerberos");

    # Add the TXT record with the realm name
    my $txtRR = { name => '_kerberos',
                  data => $ownDomain,
                  readOnly => 1 };
    $dnsMod->addText($ownDomain, $txtRR);

    # Add the SRV records to the domain
    my $service = { service => 'kerberos',
                    protocol => 'tcp',
                    port => KERBEROS_PORT,
                    priority => 100,
                    weight => 100,
                    target_type => 'domainHost',
                    target => $hostName,
                    readOnly => 1 };
    $dnsMod->addService($ownDomain, $service);
    $service->{protocol} = 'udp';
    $dnsMod->addService($ownDomain, $service);

    ## TODO Check if the server is a master or slave and adjust the target
    ##      to the master server
    $service = { service => 'kerberos-master',
                 protocol => 'tcp',
                 port => KERBEROS_PORT,
                 priority => 100,
                 weight => 100,
                 target_type => 'domainHost',
                 target => $hostName,
                 readOnly => 1 };
    $dnsMod->addService($ownDomain, $service);
    $service->{protocol} = 'udp';
    $dnsMod->addService($ownDomain, $service);

    $service = { service => 'kpasswd',
                 protocol => 'tcp',
                 port => KPASSWD_PORT,
                 priority => 100,
                 weight => 100,
                 target_type => 'domainHost',
                 target => $hostName,
                 readOnly => 1 };
    $dnsMod->addService($ownDomain, $service);
    $service->{protocol} = 'udp';
    $dnsMod->addService($ownDomain, $service);
}

# Method: enableActions
#
#   Override EBox::Module::Service::enableActions
#
sub enableActions
{
    my ($self) = @_;

    $self->_setAppArmorProfiles();

    my $mode = $self->mode();
    $self->_setupForMode();
    if ($mode eq STANDALONE_MODE) {
        $self->_internalServerEnableActions();
    } elsif ($mode eq EXTERNAL_AD_MODE) {
        $self->_externalADEnableActions();
    } else {
        throw EBox::Exceptions::Internal("Unknown mode $mode");
    }
}

sub _internalServerEnableActions
{
    my ($self) = @_;

    $self->_checkEnableIPs();

    # Setup DNS
    $self->setupDNS();

    # Execute enable-module script
    $self->SUPER::enableActions();

    # mark webAdmin as changed to avoid problems with getpwent calls, it needs
    # to be restarted to be aware of the new nsswitch conf
    EBox::Global->modInstance('webadmin')->setAsChanged();
}

sub _externalADEnableActions
{
    my ($self) = @_;
    my $global = $self->global();
    # we need to restart network to force the regeneration of DNS resolvers
    $global->modInstance('network')->setAsChanged();
    # we need to webadmin to clear DNs cache daa
    $global->modInstance('webadmin')->setAsChanged();
}

sub enableService
{
    my ($self, $status) = @_;
    my $mode = $self->mode();

    if ($status) {
        my $throwException = 1;
        if ($self->{restoringBackup}) {
            $throwException = 0;
        }

        if ($mode eq STANDALONE_MODE) {
            $self->getProvision->checkEnvironment($throwException);
        }
    }

    $self->SUPER::enableService($status);

    if ($mode eq STANDALONE_MODE) {
        my $dns = EBox::Global->modInstance('dns');
        $dns->setAsChanged();
    }
}

sub _startDaemon
{
    my ($self, $daemon, %params) = @_;

    $self->SUPER::_startDaemon($daemon, %params);

    my $services = $self->_services($daemon->{name});
    foreach my $service (@{$services}) {
        my $port = $service->{destinationPort};
        next unless $port;

        my $proto = $service->{protocol};
        next unless $proto;

        my $desc = $service->{description};
        if ($proto eq 'tcp/udp') {
            $self->_waitService('tcp', $port, $desc);
            $self->_waitService('udp', $port, $desc);
        } elsif (($proto eq 'tcp') or ($proto eq 'udp')) {
            $self->_waitService($proto, $port, $desc);
        }
    }
}

# Method: _waitService
#
#   This function will block until service is listening or timed
#   out (300 * 0.1 = 30 seconds)
#
sub _waitService
{
    my ($self, $proto, $port, $desc) = @_;

    my $maxTries = 300;
    my $sleepSeconds = 0.1;
    my $listening = 0;

    if (length ($desc)) {
        EBox::debug("Wait users task '$desc'");
    } else {
        EBox::debug("Wait unknown users task");
    }
    while (not $listening and $maxTries > 0) {
        my $sock = new IO::Socket::INET(PeerAddr => '127.0.0.1',
                                        PeerPort => $port,
                                        Proto    => $proto);
        if ($sock) {
            $listening = 1;
            last;
        }
        $maxTries--;
        Time::HiRes::sleep($sleepSeconds);
    }

    unless ($listening) {
        EBox::warn("Timeout reached while waiting for users service '$desc' ($proto)");
    }
}

sub _services
{
    my ($self) = @_;

    # TODO: separate this in different services?
    return [
            { # kerberos
                'protocol' => 'tcp/udp',
                'sourcePort' => 'any',
                'destinationPort' => '88',
                'description' => 'Kerberos authentication',
            },
            { # DCE endpoint resolution
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '135',
                'description' => 'DCE endpoint resolution',
            },
            { # netbios-ns
                'protocol' => 'udp',
                'sourcePort' => 'any',
                'destinationPort' => '137',
                'description' => 'NETBIOS name service',
            },
            { # netbios-dgm
                'protocol' => 'udp',
                'sourcePort' => 'any',
                'destinationPort' => '138',
                'description' => 'NETBIOS datagram service',
            },
            { # netbios-ssn
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '139',
                'description' => 'NETBIOS session service',
            },
            { # samba LDAP
                'protocol' => 'tcp/udp',
                'sourcePort' => 'any',
                'destinationPort' => '389',
                'description' => 'Lightweight Directory Access Protocol',
            },
            { # microsoft-ds
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '445',
                'description' => 'Microsoft directory services',
            },
            { # kerberos change/set password
                'protocol' => 'tcp/udp',
                'sourcePort' => 'any',
                'destinationPort' => '464',
                'description' => 'Kerberos set/change password',
            },
            { # LDAP over TLS/SSL
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '636',
                'description' => 'LDAP over TLS/SSL',
            },
            { # unknown???
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '1024',
            },
            { # msft-gc
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '3268',
                'description' => 'Microsoft global catalog',
            },
            { # msft-gc-ssl
                'protocol' => 'tcp',
                'sourcePort' => 'any',
                'destinationPort' => '3269',
                'description' => 'Microsoft global catalog over SSL',
            },
        ];
}


# Generate, store in the given file and return a password
sub _genPassword
{
    my ($self, $file) = @_;

    my $pass = EBox::Util::Random::generate(20);
    my ($login,$password,$uid,$gid) = getpwnam('ebox');
    EBox::Module::Base::writeFile($file, $pass,
            { mode => '0600', uid => $uid, gid => $gid });

    return $pass;
}

# Method: wizardPages
#
#   Override EBox::Module::Base::wizardPages
#
sub wizardPages
{
    my ($self) = @_;
    return [{ page => '/Samba/Wizard/Users', order => 300 }];
}

# Method: _regenConfig
#
#   Overrides <EBox::Module::Service::_regenConfig>
#
sub _regenConfig
{
    my $self = shift;

    return unless $self->configured();

    # Do provision first before adding schemas, overrides
    # default EBox::Module::LDAP behavior of adding schemas
    # first and then regenConfig
    $self->EBox::Module::Service::_regenConfig(@_);
    if ($self->mode() eq STANDALONE_MODE) {
        if ($self->isProvisioned() and $self->isEnabled()) {
            $self->_performSetup();
        }
    }
}

# Method: _setConf
#
#       Override EBox::Module::Service::_setConf
#
#  Parameters:
#    noSlaveSetup - don't setup slaves in standalone serve mode
#
sub _setConf
{
    my ($self, $noSlaveSetup) = @_;
    $self->_setupForMode();

    if ($self->mode() eq EXTERNAL_AD_MODE) {
        $self->_setConfExternalAD();
    } else {
        $self->_setConfInternal($noSlaveSetup);

        # Remove shares
        $self->model('SambaDeletedShares')->removeDirs();
        # Create shares
        $self->model('SambaShares')->createDirs();
    }
}

sub _setConfExternalAD
{
    my ($self) = @_;

    # Install cron file to update the squid keytab in the case keys change
    $self->writeConfFile(CRONFILE_EXTERNAL_AD_MODE, "samba/zentyal-users-external-ad.cron.mas", []);
    EBox::Sudo::root('chmod a+x ' . CRONFILE_EXTERNAL_AD_MODE);
    # Reset LDAP connection
    $self->clearLdapConn();
}

sub _setConfInternal
{
    my ($self, $noSlaveSetup) = @_;

    return unless $self->configured() and $self->isEnabled();

    $self->writeSambaConfig();

    my $prov = $self->getProvision();
    if ((not $prov->isProvisioned()) or $self->get('need_reprovision')) {
        if (EBox::Global->modExists('openchange')) {
            my $openchangeMod = EBox::Global->modInstance('openchange');
            if ($openchangeMod->isProvisioned()) {
                # Set OpenChange as not provisioned.
                $openchangeMod->setProvisioned(0);
            }
        }
        if ($self->get('need_reprovision')) {
            $self->_cleanModulesForReprovision();
            # Current provision is not useful, change back status to not provisioned.
            $prov->setProvisioned(0);
            # The LDB connection needs to be reset so we stop using cached values.
            $self->ldap()->clearConn()
        }
        $prov->provision();
        $self->unset('need_reprovision');
    }

    $self->writeSambaConfig();

    $self->_setupNSSPAM();

    # Slaves cron
    my @params;
    push(@params, 'slave_time' => EBox::Config::configkey('slave_time'));
    if ($self->master() eq 'cloud') {
        my $rs = new EBox::Global->modInstance('remoteservices');
        my $rest = $rs->REST();
        my $res = $rest->GET("/v1/users/realm/")->data();
        my $realm = $res->{realm};

        # Initial sync, set the realm (definitive) and upload current users
        if (not $realm) {
            $rest->PUT("/v1/users/realm/", query => { realm => $self->kerberosRealm() });

            # Send current users and groups
            $self->initialSlaveSync(new EBox::CloudSync::Slave(), 1);
        }

        push(@params, 'cloudsync_enabled' => 1);
    }

    $self->writeConfFile(CRONFILE, "samba/zentyal-users.cron.mas", \@params);

    # Configure as slave if enabled
    $self->masterConf->setupSlave() unless ($noSlaveSetup);

    # commit slaves removal
    EBox::Samba::Slave->commitRemovals($self->global());
}

sub _createDirectories
{
    my ($self) = @_;

    return unless $self->isProvisioned();

    my $zentyalUser = EBox::Config::user();
    my $group = $self->ldap->domainUsersGroup();
    my $gidNumber = $group->gidNumber();
    my $guest = $self->ldap->domainGuestUser();
    my $nobodyUidNumber = $guest->uidNumber();
    my $avModel = $self->model('AntivirusDefault');
    my $quarantine = $avModel->QUARANTINE_DIR();

    my @cmds;
    push (@cmds, 'mkdir -p ' . SAMBA_DIR);
    push (@cmds, "chown root " . SAMBA_DIR);
    push (@cmds, "chgrp '+$gidNumber' " . SAMBA_DIR);
    push (@cmds, "chmod 770 " . SAMBA_DIR);
    push (@cmds, "setfacl -b " . SAMBA_DIR);
    push (@cmds, "setfacl -m u:$nobodyUidNumber:rx " . SAMBA_DIR);
    push (@cmds, "setfacl -m u:$zentyalUser:rwx " . SAMBA_DIR);

    push (@cmds, 'mkdir -p ' . PROFILES_DIR);
    push (@cmds, "chown root " . PROFILES_DIR);
    push (@cmds, "chgrp '+$gidNumber' " . PROFILES_DIR);
    push (@cmds, "chmod 770 " . PROFILES_DIR);
    push (@cmds, "setfacl -b " . PROFILES_DIR);

    push (@cmds, 'mkdir -p ' . SHARES_DIR);
    push (@cmds, "chown root " . SHARES_DIR);
    push (@cmds, "chgrp '+$gidNumber' " . SHARES_DIR);
    push (@cmds, "chmod 770 " . SHARES_DIR);
    push (@cmds, "setfacl -b " . SHARES_DIR);
    push (@cmds, "setfacl -m u:$nobodyUidNumber:rx " . SHARES_DIR);
    push (@cmds, "setfacl -m u:$zentyalUser:rwx " . SHARES_DIR);

    push (@cmds, "mkdir -p '$quarantine'");
    push (@cmds, "chown -R $zentyalUser.adm '$quarantine'");
    push (@cmds, "chmod 770 '$quarantine'");

    EBox::Sudo::root(@cmds);
}

sub _adcMode
{
    my ($self) = @_;

    my $settings = $self->global()->modInstance('samba')->model('DomainSettings');
    return ($settings->modeValue() eq $settings->MODE_ADC());
}

sub _sysvolSyncCond
{
    my ($self) = @_;

    return ($self->isEnabled() and $self->getProvision->isProvisioned() and $self->_adcMode());
}

sub _antivirusEnabled
{
    my ($self) = @_;

    my $avModule = EBox::Global->modInstance('antivirus');
    unless (defined ($avModule) and $avModule->isEnabled()) {
        return 0;
    }

    my $avModel = $self->model('AntivirusDefault');
    my $enabled = $avModel->value('scan');

    return $enabled;
}


sub _postServiceHook
{
    my ($self, $enabled) = @_;

    return unless $enabled;

    if ($self->mode() eq EXTERNAL_AD_MODE) {
        # Update services keytabs
        my $ldap = $self->ldap();
        my @principals = @{ $ldap->externalServicesPrincipals() };
        if (scalar @principals) {
            $ldap->initKeyTabs();
        }
        return;
    }

    return unless $self->isProvisioned();

    # Fix permissions on samba dirs. Zentyal user needs access because
    # the antivirus daemon runs as 'ebox'
    $self->_createDirectories();

    my $ldap = $self->ldap();

    # Execute the hook actions *only* if Samba module is enabled and we were invoked from the web application, this will
    # prevent that we execute this code with every service restart or on server boot delaying such processes.
    if ($enabled and ($0 =~ /\/global-action$/)) {

        # Only set global roaming profiles and drive letter options
        # if we are not replicating to another Windows Server to avoid
        # overwritting already existing per-user settings. Also skip if
        # unmanaged_home_directory config key is defined
        my $unmanagedHomes = EBox::Config::boolean('unmanaged_home_directory');
        unless ($self->global()->modInstance('samba')->dcMode() eq 'adc') {
            EBox::info("Setting roaming profiles...");
            my $netbiosName = $self->netbiosName();
            my $realmName = $self->kerberosRealm();
            my $drive = $self->drive();
            my $drivePath = "\\\\$netbiosName.$realmName";
            my $profilesPath = "\\\\$netbiosName.$realmName\\profiles";

            # Skip if unmanaged_home_directory config key is defined and
            # no changes made to roaming profiles
            my $unmanagedHomes = EBox::Config::boolean('unmanaged_home_directory');
            my $state = $self->get_state();
            my $roamingProfilesChanged = delete $state->{_roamingProfilesChanged};
            $self->set_state($state);
            my $users = $self->users();
            if ($roamingProfilesChanged or not $unmanagedHomes) {
                foreach my $user (@{$users}) {
                    # Set roaming profiles
                    if ($roamingProfilesChanged) {
                        if ($self->roamingProfiles()) {
                            $user->setRoamingProfile(1, $profilesPath, 1);
                        } else {
                            $user->setRoamingProfile(0, undef, 1);
                        }
                    }

                    # Mount user home on network drive
                    $user->setHomeDrive($drive, $drivePath, 1) unless $unmanagedHomes;
                    $user->save();
                }
            }
        }

        my $host = $ldap->rootDse()->get_value('dnsHostName');
        unless (defined $host and length $host) {
            throw EBox::Exceptions::Internal('Could not get DNS hostname');
        }
        my $sambaShares = $self->model('SambaShares');
        my $domainSID = $ldap->domainSID();
        my $domainAdminSID = "$domainSID-500";
        my $domainAdminsSID = "$domainSID-512";
        my $builtinAdministratorsSID = 'S-1-5-32-544';
        my $domainUsersSID = "$domainSID-513";
        my $domainGuestSID = "$domainSID-501";
        my $domainGuestsSID = "$domainSID-514";
        my $systemSID = "S-1-5-18";
        my @superAdminSIDs = ($builtinAdministratorsSID, $domainAdminSID,
            $domainAdminsSID, $systemSID);
        my $readRights = SEC_FILE_EXECUTE | SEC_RIGHTS_FILE_READ;
        my $writeRights = SEC_RIGHTS_FILE_WRITE | SEC_STD_DELETE;
        my $adminRights = SEC_STD_ALL | SEC_RIGHTS_FILE_ALL;
        my $defaultInheritance = SEC_ACE_FLAG_CONTAINER_INHERIT | SEC_ACE_FLAG_OBJECT_INHERIT;
        my $setDescriptorError;
        for my $id (@{$sambaShares->ids()}) {
            my $row = $sambaShares->row($id);
            my $enabled     = $row->valueByName('enabled');
            my $shareName   = $row->valueByName('share');
            my $guestAccess = $row->valueByName('guest');
            my $recursiveAcls = $row->valueByName('recursive_acls');

            unless ($enabled) {
                next;
            }

            my $state = $self->get_state();
            unless (defined $state->{shares_set_rights} and $state->{shares_set_rights}->{$shareName}) {
                # share permissions didn't change, nothing needs to be done for this share.
                next;
            }

            EBox::info("Applying new permissions to the share '$shareName'...");

            my $smb = new EBox::Samba::SmbClient(
                target => $host, service => $shareName, RID => DOMAIN_RID_ADMINISTRATOR);

            # Set the client to case sensitive mode. The directory listing can
            # contain files inside folders with the same name but different
            # casing, so when trying to open them the library failes with a
            # NT_STATUS_OBJECT_NAME_NOT_FOUND error code. Setting the library
            # to case sensitive avoids this problem.
            $smb->case_sensitive(1);

            my $sd = new Samba::Security::Descriptor();
            my $sdControl = $sd->type();
            # Inherite all permissions.
            $sdControl |= SEC_DESC_DACL_AUTO_INHERITED;
            $sdControl |= SEC_DESC_DACL_PROTECTED;
            $sdControl |= SEC_DESC_SACL_AUTO_INHERITED;
            $sd->type($sdControl);
            # Set the owner and the group. We differ here from Windows because they just set the owner to
            # builtin/Administrators but this other setting should be compatible and better looking when using Linux
            # console.
            $sd->owner($domainAdminSID);
            $sd->group($builtinAdministratorsSID);

            # Always, full control to Builtin/Administrators group, Users/Administrator and System users.
            for my $superAdminSID (@superAdminSIDs) {
                my $ace = new Samba::Security::AccessControlEntry(
                    $superAdminSID, SEC_ACE_TYPE_ACCESS_ALLOWED, $adminRights, $defaultInheritance);
                $sd->dacl_add($ace);
            }

            if ($guestAccess) {
                # Add read/write access for Domain Users
                my $ace = new Samba::Security::AccessControlEntry(
                    $domainUsersSID, SEC_ACE_TYPE_ACCESS_ALLOWED, $readRights | $writeRights, $defaultInheritance);
                $sd->dacl_add($ace);
                # Add read/write access for Domain Guest user
                my $ace2 = new Samba::Security::AccessControlEntry(
                    $domainGuestSID, SEC_ACE_TYPE_ACCESS_ALLOWED, $readRights | $writeRights, $defaultInheritance);
                $sd->dacl_add($ace2);

                # Add read/write access for Domain Guests group
                my $ace3 = new Samba::Security::AccessControlEntry(
                    $domainGuestsSID, SEC_ACE_TYPE_ACCESS_ALLOWED, $readRights | $writeRights, $defaultInheritance);
                $sd->dacl_add($ace3);

                # Add everybody read/write access
                my $ace4 = new Samba::Security::AccessControlEntry(
                    'S-1-1-0', SEC_ACE_TYPE_ACCESS_ALLOWED, $readRights | $writeRights, $defaultInheritance);
                $sd->dacl_add($ace4);
            } else {
                for my $subId (@{$row->subModel('access')->ids()}) {
                    my $subRow = $row->subModel('access')->row($subId);
                    my $permissions = $subRow->elementByName('permissions');

                    my $userType = $subRow->elementByName('user_group');
                    my $account = $userType->value();
                    my $object = new EBox::Samba::SecurityPrincipal(samAccountName => $account);
                    next unless ($object->exists());

                    my $sid = $object->sid();

                    my $rights = undef;
                    if ($permissions->value() eq 'readOnly') {
                        $rights = $readRights;
                    } elsif ($permissions->value() eq 'readWrite') {
                        $rights = $readRights | $writeRights;
                    } elsif ($permissions->value() eq 'administrator') {
                        $rights = $adminRights;
                    } else {
                        my $type = $permissions->value();
                        EBox::error("Unknown share permission type '$type'");
                        next;
                    }
                    my $ace = new Samba::Security::AccessControlEntry(
                        $sid, SEC_ACE_TYPE_ACCESS_ALLOWED, $rights, $defaultInheritance);
                    $sd->dacl_add($ace);
                }
            }
            my $relativeSharePath = '/';
            EBox::info("Applying ACLs for top-level share $shareName");
            my $sinfo = SECINFO_OWNER |
                        SECINFO_GROUP |
                        SECINFO_DACL |
                        SECINFO_PROTECTED_DACL;
            my $access_mask = SEC_STD_WRITE_OWNER |
                              SEC_STD_READ_CONTROL |
                              SEC_STD_WRITE_DAC |
                              SEC_FILE_READ_ATTRIBUTE;
            my $attributes = FILE_ATTRIBUTE_NORMAL |
                             FILE_ATTRIBUTE_ARCHIVE |
                             FILE_ATTRIBUTE_DIRECTORY |
                             FILE_ATTRIBUTE_HIDDEN |
                             FILE_ATTRIBUTE_READONLY |
                             FILE_ATTRIBUTE_SYSTEM;
            try {
                EBox::debug("Setting NT ACL on file: $relativeSharePath");
                $smb->set_sd($relativeSharePath, $sd, $sinfo, $access_mask);
            } catch ($ex) {
                EBox::error(
                    __x("Error setting security descriptor on share '{x}': {y}",
                        x => $shareName, y => $ex));
                $setDescriptorError = 1;
            }

            # Apply recursively the permissions.
            my $shareContentList = $smb->list($relativeSharePath,
                attributes => $attributes, recursive => 1);
            # Reset the DACL_PROTECTED flag;
            $sdControl = $sd->type();
            $sdControl &= ~SEC_DESC_DACL_PROTECTED;
            $sd->type($sdControl);
            ## only replace ACLs for subdirs if recursiveAcls = 1
            if ($recursiveAcls) {
                foreach my $item (@{$shareContentList}) {
                    my $itemName = $item->{name};
                    $itemName =~ s/^\/\/(.*)/\/$1/s;
                    try {
                        EBox::debug("Replacing ACLs for $shareName$itemName");
                        $smb->set_sd($itemName, $sd, $sinfo, $access_mask);
                    } catch ($ex) {
                        EBox::error(
                            __x("Error setting security descriptor on file {x}{y}: {z}",
                                x => $shareName, y => $itemName, z => $ex));
                        $setDescriptorError = 1;
                    }
                }
            }
            delete $state->{shares_set_rights}->{$shareName};
            $self->set_state($state);
        }

        # Change group ownership of quarantine_dir to __USERS__
        EBox::info("Fixing quarantine_dir permissions...");
        if ($self->defaultAntivirusSettings()) {
            $self->_setupQuarantineDirectory();
        }

        # Write DNS update list
        EBox::info("Writing DNS update list...");
        $self->_writeDnsUpdateList();

        # Show warning if error setting ACLs
        if ($setDescriptorError) {
            $self->global->addSaveMessage(
                __("There were errors setting ACLs on samba shares, " .
                    "please check the zentyal log for details."));
        }
    } else {
        EBox::debug("Ignoring Samba's _postServiceHook code because it was not invoked from the web application.");
    }

    return $self->SUPER::_postServiceHook($enabled);
}


# overriden to revoke slave removals
sub revokeConfig
{
   my ($self) = @_;
   $self->SUPER::revokeConfig();
   EBox::Samba::Slave->revokeRemovals($self->global());
}

sub kerberosRealm
{
    my ($self) = @_;

    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $realm = uc ($sysinfo->hostDomain());
    return $realm;
}

# Set up NSS PAM for LDB users
sub _setupNSSPAM
{
    my ($self) = @_;

    my @array = ();
    my $umask = EBox::Config::configkey('dir_umask');
    push (@array, 'umask' => $umask);

    $self->writeConfFile(AUTHCONFIGTMPL, 'samba/acc-zentyal.mas',
                         \@array);

    my $PAMModule = $self->model('PAM');
    my $enablePAM = $PAMModule->enable_pamValue();
    $self->_setupSSSd($PAMModule->login_shellValue());

    my $cmd;
    if ($enablePAM) {
        $cmd = 'auth-client-config -a -p zentyal-krb';
    } else {
        $cmd = 'auth-client-config -a -p zentyal-nokrb';
    }
    EBox::Sudo::root($cmd);
}

# Set up SSS daemon
sub _setupSSSd
{
    my ($self, $defaultShell) = @_;

    my $sysinfo = $self->global()->modInstance('sysinfo');
    my @params = ('fqdn'   => $sysinfo->fqdn(),
                  'domain' => $sysinfo->hostDomain(),
                  'defaultShell' => $defaultShell,
                  'keyTab' => SECRETS_KEYTAB);

    # SSSd conf file must be owned by root and only rw by him
    $self->writeConfFile(SSSD_CONF_FILE, 'samba/sssd.conf.mas',
                         \@params,
                         {'mode' => '0600', uid => 0, gid => 0});
}

# Method: editableMode
#
#       Check if users and groups can be edited.
#
#       They could not be edited ither mode is external-ad or the syncprovider
#       does not allows it
#
sub editableMode
{
    my ($self) = @_;
    if ($self->mode() ne STANDALONE_MODE) {
        return 0;
    }

    my $global = EBox::Global->modInstance('global');
    my @names = @{$global->modNames};

    my @modules;
    foreach my $name (@names) {
        my $mod = EBox::Global->modInstance($name);

        if ($mod->isa('EBox::Samba::SyncProvider')) {
            return 0 unless ($mod->allowUserChanges());
        }
    }

    return 1;
}

# Method: _daemons
#
#       Override EBox::Module::Service::_daemons
#
sub _daemons
{
    my ($self) = @_;

    my $usingInternalServer = sub {
        return ($self->mode() eq STANDALONE_MODE);
    };

    my $enabledAndProvisioned = sub {
        return ($self->isEnabled() and $self->isProvisioned());
    };

    return [
        {
            name => 'samba-ad-dc',
            precondition => $usingInternalServer
        },
        {
            name => 'sssd',
            precondition => $usingInternalServer
        },
        {
            name => 'zentyal.sysvol-sync',
            precondition => \&_sysvolSyncCond,
        },
        {
            name => 'zentyal.zavsd',
            precondition => \&_antivirusEnabled,
        },
        {
            name => 'zentyal.set-uid-gid-numbers',
            precondition => $enabledAndProvisioned,
        },
    ];
}

# Method: _daemonsToDisable
#
# Overrides:
#
#   <EBox::Module::Service::_daemonsToDisable>
#
sub _daemonsToDisable
{
    return [
        { 'name' => 'smbd', 'type' => 'upstart' },
        { 'name' => 'nmbd', 'type' => 'upstart' },
    ];
}

# Function: usesPort
#
#   Implements EBox::FirewallObserver interface
#
sub usesPort
{
    my ($self, $protocol, $port, $iface) = @_;

    return undef unless($self->isEnabled());

    foreach my $smbport (@{$self->_services()}) {
        return 1 if ($port eq $smbport->{destinationPort});
    }

    return undef;
}


# Method: _startService
#
#   Overrided to ensure proper permissions of the ldap_priv folder, where the
#   privileged socket that zentyal uses to connect is. This is a special socket
#   that samba create that allow r/w restricted attributes.
#   Samba expects the ldap_priv folder to be owned by root and mode 0750, or the
#   LDAP service won't run.
#
#   Here we set the expected permissions before start the daemon.
#
sub _startService
{
    my ($self) = @_;

    my $group = EBox::Config::group();
    EBox::Sudo::root("mkdir -p " . SAMBA_PRIVILEGED_SOCKET);
    EBox::Sudo::root("chgrp $group " . SAMBA_PRIVILEGED_SOCKET);
    EBox::Sudo::root("chmod 0750 " . SAMBA_PRIVILEGED_SOCKET);
    EBox::Sudo::root("setfacl -b " . SAMBA_PRIVILEGED_SOCKET);

    $self->SUPER::_startService();

    if ($self->mode() eq STANDALONE_MODE) {
        # Wait for sss to open the NSS pipe
        my $tries = 300;
        my $sleep = 0.1;
        my $socket = undef;
        while (not defined $socket and $tries > 0) {
            $socket = new IO::Socket::UNIX(
                Type => SOCK_STREAM,
                Peer => '/var/lib/sss/pipes/nss');
            last if $socket;
            $tries--;
            Time::HiRes::sleep($sleep);
        }
    }
}

# Method: groupDn
#
#    Returns the dn for a given group. The group doesn't have to exist
#
#   Parameters:
#       group
#
#  Returns:
#     dn for the group
#
# FIXME: This should not be used anymore...
sub groupDn
{
    my ($self, $group) = @_;
    $group or throw EBox::Exceptions::MissingArgument('group');

    my $dn = "cn=$group," . EBox::Samba::Group->defaultContainer()->dn();
    return $dn;
}

# Init a new user (home and permissions)
sub initUser
{
    my ($self, $user) = @_;

    my $mk_home = EBox::Config::configkey('mk_home');
    $mk_home = 'yes' unless $mk_home;
    if ($mk_home eq 'yes') {
        my $home = $user->home();
        if ($home and ($home ne '/dev/null') and (not -e $home)) {
            my $qhome = shell_quote($home);
            my $gidNumber = $user->gidNumber();
            my $uidNumber = $user->uidNumber();

            my @cmds;
            push (@cmds, "mkdir -p `dirname $qhome`");
            push (@cmds, "cp -dR --preserve=mode /etc/skel $qhome");
            push (@cmds, "chown -R +$uidNumber:+$gidNumber $qhome");

            my $dir_umask = oct(EBox::Config::configkey('dir_umask'));
            my $perms = sprintf("%#o", 00777 &~ $dir_umask);
            push (@cmds, "chmod $perms $qhome");
            EBox::Sudo::root(@cmds);
        }
    }
}

# Reload nscd daemon if it's installed
sub reloadNSCD
{
    if (-f '/etc/init.d/nscd') {
        try {
            EBox::Sudo::root('service nscd force-reload');
        } catch {
        }
   }
}

# Method: containers
#
#   Returns an array containing all the containers. The array is ordered in a
#   hierarquical way. Parents before childs.
#
# Returns:
#
#   array ref - holding the containers. Each member is represented by a
#   EBox::Samba::Container object
#
sub containers
{
    my ($self, $baseDN) = @_;

    my $list = [];

    return $list if (not $self->isEnabled());

    unless (defined $baseDN) {
        $baseDN = $self->ldap->dn();
    }

    my $searchArgs = {
        base => $baseDN,
        filter => "(objectclass=container)",
        scope => 'one',
        attrs => ['*'],
    };

    my @entries = @{$self->ldap->pagedSearch($searchArgs)};
    foreach my $entry (@entries) {
        my $container = new EBox::Samba::Container(entry => $entry);
        push (@{$list}, $container);
        my $nested = $self->containers($container->dn());
        push (@{$list}, @{$nested});
    }

    return $list;
}

# Method: ous
#
#   Returns an array containing all the OUs. The array ir ordered in a
#   hierarquical way. Parents before childs.
#
# Returns:
#
#   array ref - holding the OUs. Each user is represented by a
#   EBox::Samba::OU object
#
sub ous
{
    my ($self, $baseDN) = @_;

    my $list = [];

    return $list if (not $self->isEnabled());

    unless (defined $baseDN) {
        $baseDN = $self->ldap->dn();
    }

    my $args = {
        base => $baseDN,
        filter => "(objectclass=organizationalUnit)",
        scope => 'one',
    };

    my @entries = @{$self->ldap->pagedSearch($args)};
    foreach my $entry (@entries) {
        my $ou = new EBox::Samba::OU(entry => $entry);
        push (@{$list}, $ou);
        my $nested = $self->ous($ou->dn());
        push (@{$list}, @{$nested});
    }

    return $list;
}

# Method: userByUID
#
#   Return the instance of EBox::Samba::User object which represents a given
#   uid or undef if it's not found. Used by cloud-sync.
#
# Parameters:
#
#   uid
#
sub userByUID
{
    my ($self, $uid) = @_;

    return undef unless ($self->isEnabled());

    my $args = {
        base => $self->ldap->dn(),
        filter => "(&(&(objectclass=user)(!(objectclass=computer)))(!(isDeleted=*))(samAccountName=$uid))",
        scope => 'sub',
        attrs => ['*'],
    };

    my $result = $self->ldap->search($args);
    my $count = $result->count();
    if ($count > 1) {
        throw EBox::Exceptions::Internal(
            __x('Found {count} results for \'{uid}\' user, expected only one.',
                count => $count,
                name  => $uid
            )
        );
    } elsif ($count == 0) {
        return undef;
    } else {
        return new EBox::Samba::User(entry => $result->entry(0));
    }
}

# Method: users
#
#   Returns an array containing all the users (not system users)
#
# Parameters:
#
#   system - show system users also (default: false)
#
# Returns:
#
#   array ref - holding the users. Each user is represented by a
#               EBox::Samba::User object
#
sub users
{
    my ($self, $system) = @_;

    my $list = [];

    return $list if (not $self->isEnabled());

    # Query the containers stored in the root DN and skip the ignored ones
    # Note that 'OrganizationalUnit' and 'msExchSystemObjectsContainer' are
    # subclasses of 'Container'.
    my @containers;
    my $params = {
        base => $self->ldap->dn(),
        scope => 'one',
        filter => '(|(objectClass=container)(objectClass=organizationalUnit)(objectClass=msExchSystemObjectsContainer))',
        attrs => ['*'],
    };
    my @entries = @{$self->ldap->pagedSearch($params)};
    @entries = sort {
            my $aValue = $a->get_value('name');
            my $bValue = $b->get_value('name');
            (lc $aValue cmp lc $bValue) or ($aValue cmp $bValue)
    } @entries;
    foreach my $entry (@entries) {
        my $container = new EBox::Samba::Container(entry => $entry);
        next if $container->get('cn') eq any EBox::Ldap::QUERY_IGNORE_CONTAINERS();
        push (@containers, $container);
    }

    # Query the users stored in the non ignored containers
    my $filter = "(&(&(objectclass=user)(!(objectclass=computer)))(!(isDeleted=*)))";
    foreach my $container (@containers) {
        $params = {
            base   => $container->dn(),
            scope  => 'sub',
            filter => $filter,
            attrs  => ['*', 'unicodePwd', 'supplementalCredentials'],
        };
        @entries = @{$self->ldap->pagedSearch($params)};
        @entries = sort {
                my $aValue = $a->get_value('samAccountName');
                my $bValue = $b->get_value('samAccountName');
                (lc $aValue cmp lc $bValue) or ($aValue cmp $bValue)
        } @entries;
        foreach my $entry (@entries) {
            my $user = new EBox::Samba::User(entry => $entry);
            next if (not $system and $user->isSystem());
            push (@{$list}, $user);
        }
    }

    return $list;
}

# Method: realUsers
#
#       Returns an array containing all the non-internal users
#
# Returns:
#
#       array ref - holding the users. Each user is represented by a
#       EBox::Samba::User object
#
sub realUsers
{
    my ($self) = @_;

    my @users = grep { not $_->isInternal() and not $_->isAdministratorOrGuest() } @{$self->users()};

    return \@users;
}

# Method: realGroups
#
#       Returns an array containing all the non-internal groups
#
# Returns:
#
#       array ref - holding the groups. Each user is represented by a
#       EBox::Samba::Group object
#
sub realGroups
{
    my ($self) = @_;

    my @groups = grep { not $_->isInternal() } @{$self->securityGroups()};

    return \@groups;
}

# Method: contactsByName
#
# Return a reference to a list of instances of EBox::Samba::Contact objects which represents a given name.
#
#  Parameters:
#      name
#
sub contactsByName
{
    my ($self, $name) = @_;

    my $list = [];

    return $list if (not $self->isEnabled());

    my $params = {
        base => $self->ldap->dn(),
        scope => 'sub',
        filter => "(&(objectclass=contact)(!(isDeleted=*))(cn=$name))",
        attrs => ['*'],
    };
    my @entries = @{$self->ldap->pagedSearch($params)};
    @entries = sort {
            my $aValue = $a->get_value('cn');
            my $bValue = $b->get_value('cn');
            (lc $aValue cmp lc $bValue) or ($aValue cmp $bValue)
    } @entries;
    foreach my $entry (@entries) {
        my $contact = new EBox::Samba::Contact(entry => $entry);
        push (@{$list}, $contact);
    }
    return $list;
}

# Method: contactExists
#
#  Returns:
#
#      bool - whether the contact exists or not
#
sub contactExists
{
    my ($self, $name) = @_;
    return undef unless ($self->contactsByName($name));
    return 1;
}

# Method: contacts
#
#       Returns an array containing all the contacts
#
# Returns:
#
#       array ref - holding the contacts. Each contact is represented by a
#       EBox::Samba::Contact object
#
sub contacts
{
    my ($self) = @_;

    return [] if (not $self->isEnabled());

    my %args = (
        base => $self->ldap->dn(),
        filter => '(&(objectclass=inetOrgPerson)(!(objectclass=posixAccount)))',
        scope => 'sub',
    );

    my $result = $self->ldap->search(\%args);

    my @contacts = ();
    foreach my $entry ($result->entries) {
        my $contact = new EBox::Samba::Contact(entry => $entry);

        push (@contacts, $contact);
    }

    # sort by name
    @contacts = sort {
        my $aValue = $a->fullname();
        my $bValue = $b->fullname();
        (lc $aValue cmp lc $bValue) or ($aValue cmp $bValue)
    } @contacts;

    return \@contacts;
}

# Method: groupByName
#
# Return the instance of EBox::Samba::Group object which represents a give group name or undef if it's not found.
#
#  Parameters:
#      name
#
sub groupByName
{
    my ($self, $name) = @_;

    return undef unless ($self->isEnabled());

    my $args = {
        base => $self->ldap->dn(),
        filter => "(&(objectclass=group)(!(isDeleted=*))(cn=$name))",
        scope => 'sub',
        attrs => ['*'],
    };

    my $result = $self->ldap->search($args);
    my $count = $result->count();
    if ($count > 1) {
        throw EBox::Exceptions::Internal(
            __x('Found {count} results for \'{name}\' group, expected only one.',
                count => $count,
                name  => $name
            )
        );
    } elsif ($count == 0) {
        return undef;
    } else {
        return new EBox::Samba::Group(entry => $result->entry(0));
    }
}

# Method: groups
#
#       Returns an array containing all the groups
#
#   Parameters:
#       system - show system groups (default: false)
#
# Returns:
#
#       array - holding the groups as EBox::Samba::Group objects
#
sub groups
{
    my ($self, $system) = @_;

    return [] if (not $self->isEnabled());

    my $list = [];
    my $params = {
        base => $self->ldap->dn(),
        scope => 'sub',
        filter => '(&(objectclass=group)(!(isDeleted=*)))',
        attrs => ['*'],
    };
    my @entries = @{$self->ldap->pagedSearch($params)};
    @entries = sort {
            my $aValue = $a->get_value('samAccountName');
            my $bValue = $b->get_value('samAccountName');
            (lc $aValue cmp lc $bValue) or ($aValue cmp $bValue)
     } @entries;
    foreach my $entry (@entries) {
        my $group = new EBox::Samba::Group(entry => $entry);
        next if (not $system and $group->isSystem());
        push (@{$list}, $group);
    }

    return $list;
}

# Method: securityGroups
#
#   Returns an array containing all the security groups
#
# Parameters:
#
#   system - show system groups (default: false)
#
# Returns:
#
#   array - holding the groups as EBox::Samba::Group objects
#
sub securityGroups
{
    my ($self, $system) = @_;

    my $list = [];

    return $list if (not $self->isEnabled());

    my $groups = $self->groups($system);
    foreach my $group (@{$groups}) {
        next unless $group->isSecurityGroup();
        next if (not $system and $group->isSystem());
        push (@{$list}, $group);
    }

    return $list;
}

# Method: _modsLdapUserbase
#
# Returns modules implementing LDAP user base interface
#
# Parameters:
#   ignored_modules (Optional) - array ref to a list of module names to ignore
#
sub _modsLdapUserBase
{
    my ($self, $ignored_modules) = @_;

    my $global = EBox::Global->modInstance('global');
    my @names = @{$global->modNames};

    $ignored_modules or $ignored_modules = [];

    my @modules;
    foreach my $name (@names) {
        next if ($name eq any @{$ignored_modules});

        my $mod = EBox::Global->modInstance($name);

        if ($mod->isa('EBox::Module::LDAP')) {
            if ($name ne $self->name()) {
                $mod->configured() or
                    next;
            }
            push (@modules, $mod->_ldapModImplementation);
        }
    }

    return \@modules;
}

# Method: allSlaves
#
# Returns all slaves from LDAP Sync Provider
#
sub allSlaves
{
    my ($self) = @_;

    my $global = EBox::Global->modInstance('global');
    my @names = @{$global->modNames};

    my @modules;
    foreach my $name (@names) {
        my $mod = EBox::Global->modInstance($name);

        if ($mod->isa('EBox::Samba::SyncProvider')) {
            push (@modules, @{$mod->slaves()});
        }
    }

    return \@modules;
}

# Method: notifyModsPreLdapUserBase
#
#   Notify all modules implementing LDAP user base interface about
#   a change in users or groups before it happen.
#
# Parameters:
#
#   signal - Signal name to notify the modules (addUser, delUser, modifyGroup, ...)
#   args - single value or array ref containing signal parameters
#   ignored_modules - array ref of modnames to ignore (won't be notified)
#
sub notifyModsPreLdapUserBase
{
    my ($self, $signal, $args, $ignored_modules) = @_;

    # convert signal to method name
    my $method = '_' . $signal;

    # convert args to array if it is a single value
    unless (ref ($args) eq 'ARRAY') {
        $args = [ $args ];
    }

    foreach my $mod (@{$self->_modsLdapUserBase($ignored_modules)}) {
        $mod->$method(@{$args});
    }
}

# Method: notifyModsLdapUserBase
#
#   Notify all modules implementing LDAP user base interface about
#   a change in users or groups
#
# Parameters:
#
#   signal - Signal name to notify the modules (addUser, delUser, modifyGroup, ...)
#   args - single value or array ref containing signal parameters
#   ignored_modules - array ref of modnames to ignore (won't be notified)
#   ignored_slaves -
#
sub notifyModsLdapUserBase
{
    my ($self, $signal, $args, $ignored_modules, $ignored_slaves) = @_;

    # convert signal to method name
    my $method = '_' . $signal;

    # convert args to array if it is a single value
    unless (ref($args) eq 'ARRAY') {
        $args = [ $args ];
    }

    my $defaultOU = $args->[0]->isInDefaultContainer();
    foreach my $mod (@{$self->_modsLdapUserBase($ignored_modules)}) {

        # Skip modules not supporting multiple OU if not default OU
        next unless ($mod->multipleOUSupport or $defaultOU);

        # TODO catch errors here? Not a good idea. The way to go is
        # to implement full transaction support and rollback if a notified
        # module throws an exception
        $mod->$method(@{$args});
    }

    # Notify slaves
    $ignored_slaves or $ignored_slaves = [];
    foreach my $slave (@{$self->allSlaves}) {
        my $name = $slave->name();
        next if ($name eq any @{$ignored_slaves});

        $slave->sync($signal, $args);
    }
}

# Method: initialSlaveSync
#
#   This method will send a sync signal for each
#   stored user and group.
#   It should be called on a slave registering
#
#   If sync parameter is given, the operation will
#   be sent instantly, if not, it will be saved for
#   slave-sync daemon
#
sub initialSlaveSync
{
    my ($self, $slave, $sync) = @_;

    foreach my $user (@{$self->realUsers()}) {
        if ($sync) {
            $slave->sync('addUser', [ $user ]);
        } else {
            $slave->savePendingSync('addUser', [ $user ]);
        }
    }

    foreach my $group (@{$self->groups()}) {
        if ($sync) {
            $slave->sync('addGroup', [ $group ]);
            $slave->sync('modifyGroup', [ $group ]);
        } else {
            $slave->savePendingSync('addGroup', [ $group ]);
            $slave->savePendingSync('modifyGroup', [ $group ]);
        }
    }
}

# Method: defaultUserModels
#
#   Returns all the defaultUserModels from modules implementing
#   <EBox::LdapUserBase>
sub defaultUserModels
{
    my ($self) = @_;
    my @models;
    for my $module  (@{$self->_modsLdapUserBase()}) {
        my $model = $module->defaultUserModel();
        push (@models, $model) if (defined($model));
    }
    return \@models;
}

# Method: allUserAddOns
#
#       Returns all the mason components from those modules implementing
#       the function _userAddOns from EBox::LdapUserBase
#
# Parameters:
#
#       user - user object
#
# Returns:
#
#       array ref - holding all the components and parameters
#
sub allUserAddOns
{
    my ($self, $user) = @_;

    my $defaultOU = ($user->baseDn() eq $user->defaultContainer()->dn());

    my @modsFunc = @{$self->_modsLdapUserBase()};
    my @components;
    foreach my $mod (@modsFunc) {
        my $comp;
        if ($defaultOU or $mod->multipleOUSupport) {
            $comp = $mod->_userAddOns($user);
        } else {
            $comp  = $mod->noMultipleOUSupportComponent($user);
        }

        if ($comp) {
            $comp->{id} = ref $mod;
            $comp->{id} =~ s/:/_/g;
            push (@components, $comp);
        }
    }

    return \@components;
}

# Method: allGroupAddOns
#
#       Returns all the mason components from those modules implementing
#       the function _groupAddOns from EBox::LdapUserBase
#
# Parameters:
#
#       group  - group name
#
# Returns:
#
#       array ref - holding all the components and parameters
#
sub allGroupAddOns
{
    my ($self, $group) = @_;

    my $global = EBox::Global->modInstance('global');
    my @names = @{$global->modNames};

    my @modsFunc = @{$self->_modsLdapUserBase()};
    my @components;
    foreach my $mod (@modsFunc) {
        my $comp = $mod->_groupAddOns($group);
        if ($comp) {
            $comp->{id} = ref $mod;
            $comp->{id} =~ s/:/_/g;
            push (@components, $comp) if ($comp);
        }
    }

    return \@components;
}

# Method: allWarnings
#
#       Returns all the the warnings provided by the modules when a certain
#       user, group is going to be deleted. Function _delUserWarning or
#       _delGroupWarning is called in all module implementing them.
#
# Parameters:
#
#       object - Sort of object: 'user' or 'group'
#       name - name of the user or group
#
# Returns:
#
#       array ref - holding all the warnings
#
sub allWarnings
{
    my ($self, $object, $name) = @_;

    # TODO: Extend it for ous and contacts.
    return [] unless (($object eq 'user') or ($object eq 'group'));

    my @modsFunc = @{$self->_modsLdapUserBase()};
    my @allWarns;
    foreach my $mod (@modsFunc) {
        my $warn = undef;
        if ($object eq 'user') {
            $warn = $mod->_delUserWarning($name);
        } else {
            $warn = $mod->_delGroupWarning($name);
        }
        push (@allWarns, $warn) if ($warn);
    }

    return \@allWarns;
}

# Method: _supportActions
#
#       Overrides EBox::ServiceModule::ServiceInterface method.
#
sub _supportActions
{
    return undef;
}

# Method: menu
#
#       Overrides EBox::Module method.
#
sub menu
{
    my ($self, $root) = @_;

    my $standalone = ($self->mode eq STANDALONE_MODE);

    if ($standalone) {
        my $domainFolder = new EBox::Menu::Folder(name => 'Domain',
                                                  text => __('Domain'),
                                                  icon => 'domain',
                                                  tag => 'main',
                                                  order => 2);

        $domainFolder->add(new EBox::Menu::Item(url   => 'Samba/View/DomainSettings',
                                                text  => __('Settings'),
                                                order => 10));

        $domainFolder->add(new EBox::Menu::Item(url   => 'Samba/View/GPOs',
                                                text  => __('Group Policy Objects'),
                                                order => 20));
        $domainFolder->add(new EBox::Menu::Item(url   => 'Samba/Tree/GPOLinks',
                                                text  => __('Group Policy Links'),
                                                order => 30));

        $root->add($domainFolder);
    }


    my $folder = new EBox::Menu::Folder(name => 'Users',
                                        icon => 'samba',
                                        text => __('Users and Computers'),
                                        tag => 'main',
                                        order => 1);
    if ($self->configured()) {
        $folder->add(new EBox::Menu::Item(
            'url'  => 'Samba/Tree/Manage',
            'text' => __('Manage'), order => 10));

        if ($standalone) {
            $folder->add(new EBox::Menu::Item(
                'url'  => 'Samba/Composite/UserTemplate',
                'text' => __('User Template'), order => 30));
            if ($self->mode() eq STANDALONE_MODE) {
                $folder->add(new EBox::Menu::Item(
                    'url'  => 'Samba/View/Master',
                    'text' => __('Synchronization'), order => 40));
            }
        }

        $folder->add(new EBox::Menu::Item(
            'url'  => 'Samba/Composite/Settings',
            'text' => __('LDAP Settings'), order => 50));
    } else {
        $folder->add(new EBox::Menu::Item(
            'url'       => 'Samba/View/Mode',
            'text'      => __('Configure mode'),
            'section'   => 3,
            'order'     => 0));
    }
    $root->add($folder);

    if ($standalone) {
        $root->add(new EBox::Menu::Item(text      => __('File Sharing'),
                                        url       => 'Samba/Composite/FileSharing',
                                        icon      => 'sharing',
                                        tag       => 'main',
                                        order     => 3));
    }
}

# Method: enableModDepends
#
# Overriden to remove dns from dependencies when on standalone mode
sub enableModDepends
{
    my ($self) = @_;
    my $depends = $self->SUPER::enableModDepends();
    return $self->_filterDependsByMode($depends);
}

# Method: bootDepends
#
# Overriden to remove dns from dependencies when on standalone mode
sub bootDepends
{
    my ($self)= @_;
    my $depends = $self->SUPER::bootDepends();
    return $self->_filterDependsByMode($depends);
}

# Method: depends
#
#     Samba depends on printers only if it exists and in standalone mode
#
# Overrides:
#
#     <EBox::Module::Base::depends>
#
sub depends
{
    my ($self) = @_;

    my @deps = @{$self->SUPER::depends()};

    if ($self->global()->modExists('printers')) {
        push (@deps, 'printers');
    }

    return $self->_filterDependsByMode(\@deps);
}

sub _filterDependsByMode
{
    my ($self, $depends) = @_;
    my $mode = $self->mode();
    if ($mode eq STANDALONE_MODE) {
        return $depends;
    } elsif ($mode eq EXTERNAL_AD_MODE) {
        my @depends = grep {
            ($_ ne 'dns') and ($_ ne 'printers')
        } @{ $depends };

        return \@depends;
    } else {
        throw EBox::Exceptions::Internal("Unknown users mode '$mode'");
    }
}

# Method: syncJournalDir
#
#   Returns the path holding sync pending actions for
#   the given slave.
#   If the directory does not exists, it will be created;
#
sub syncJournalDir
{
    my ($self, $slave, $notCreate) = @_;

    my $dir = JOURNAL_DIR . $slave->name();
    my $journalsDir = JOURNAL_DIR;

    unless ($notCreate) {
        # Create if the dir does not exists
        unless (-d $dir) {
            EBox::Sudo::root(
                "mkdir -p $dir",
                "chown -R ebox:ebox $journalsDir",
                "chmod 0700 $journalsDir",
               );
        }
    }

    return $dir;
}

# LdapModule implementation
sub _ldapModImplementation
{
    return new EBox::LdapUserImplementation();
}

# SyncProvider implementation

# Method: slaves
#
#    Get the slaves for this server
#
# Returns:
#
#    array ref - containing the slaves for this server. Zentyal server slaves are
#                <EBox::UsersSync::Slave> instances and Zentyal Cloud slave is
#                a <EBox::CloudSync::Slave> instance.
#
sub slaves
{
    my ($self) = @_;

    my $model = $self->model('Slaves');

    my @slaves;
    foreach my $id (@{$model->ids()}) {
        my $row = $model->row($id);
        my $host = $row->valueByName('host');
        my $port = $row->valueByName('port');

        push (@slaves, new EBox::UsersSync::Slave($host, $port, $id));
    }

    my $g = EBox::Global->getInstance(1);
    my $u = $g->modInstance('samba');
    if ($u->master() eq 'cloud') {
        push (@slaves, new EBox::CloudSync::Slave());
    }

    return \@slaves;
}

# Method: master
#
#   Return configured master as string, undef in none
#
#   Options: 'zentyal', 'cloud' or None
#
sub master
{
    my ($self) = @_;
    return $self->model('Master')->master();
}

# SyncProvider implementation
sub allowUserChanges
{
    my ($self) = @_;

    return (not $self->masterConf->isSlave());
}

# Master-Slave UsersSync object
sub masterConf
{
    my ($self) = @_;

    unless ($self->{ms}) {
        $self->{ms} = new EBox::UsersSync::Master();
    }
    return $self->{ms};
}

sub dumpConfig
{
    my ($self, $dir, %options) = @_;

    return unless $self->isProvisioned();

    my $mode = $self->mode();
    File::Slurp::write_file($dir . '/' . BACKUP_MODE_FILE, $mode);
    if ($mode ne STANDALONE_MODE) {
        # the dump of the LDAP is only availabe in standalone server mode
        return;
    }

    my @cmds;

    my $hostname  =  `hostname --fqdn`;
    chomp $hostname;
    File::Slurp::write_file("$dir/oldhostname", $hostname);

    my $mirror = EBox::Config::tmp() . "/samba.backup";
    my $privateDir = PRIVATE_DIR;
    if (EBox::Sudo::fileTest('-d', $privateDir)) {
        # Export the list of users to a file. On restore this list will be
        # loaded to check no users exists in /etc/passwd with same name as
        # any user backed up
        my $users = $self->users();
        my @users = map { $_->get('samAccountName') } @{$users};
        File::Slurp::write_file($dir . '/' . BACKUP_USERS_FILE, join("\n", @users));

        # Remove previous backup files
        my $ldbBakFiles = EBox::Sudo::root("find $privateDir -name '*.ldb.bak'");
        my $tdbBakFiles = EBox::Sudo::root("find $privateDir -name '*.tdb.bak'");
        foreach my $bakFile ((@{$ldbBakFiles}, @{$tdbBakFiles})) {
            chomp ($bakFile);
            push (@cmds, "rm '$bakFile'");
        }

        # Backup private. TDB and LDB files must be backed up using tdbbackup
        my $ldbFiles = EBox::Sudo::root("find $privateDir -name '*.ldb'");
        my $tdbFiles = EBox::Sudo::root("find $privateDir -name '*.tdb'");
        foreach my $dbFile ((@{$ldbFiles}, @{$tdbFiles})) {
            chomp ($dbFile);
            push (@cmds, "tdbbackup '$dbFile'");
            # Preserve file permissions
            my $st = EBox::Sudo::stat($dbFile);
            my $uid = $st->uid();
            my $gid = $st->gid();
            my $mode = sprintf ("%04o", $st->mode() & 07777);
            push (@cmds, "chown $uid:$gid $dbFile.bak");
            push (@cmds, "chmod $mode $dbFile.bak");
        }

        push (@cmds, "rm -rf $mirror");
        push (@cmds, "mkdir -p $mirror/private");
        push (@cmds, "rsync -HAXavz $privateDir/ " .
                     "--exclude=*.tdb --exclude=*.ldb " .
                     "--exclude=ldap_priv --exclude=smbd.tmp " .
                     "--exclude=ldapi $mirror/private");
        push (@cmds, "tar pcjf $dir/private.tar.bz2 --hard-dereference -C $mirror private");
    }

    # Backup sysvol
    my $sysvolDir = SYSVOL_DIR;
    if (EBox::Sudo::fileTest('-d', $sysvolDir)) {
        push (@cmds, "rm -rf $mirror");
        push (@cmds, "mkdir -p $mirror/sysvol");
        push (@cmds, "rsync -HAXavz $sysvolDir/ $mirror/sysvol");
        push (@cmds, "tar pcjf $dir/sysvol.tar.bz2 --hard-dereference -C $mirror sysvol");
    }

    try {
        EBox::Sudo::root(@cmds);
    } catch ($e) {
        $e->throw();
    }

    # Backup admin password
    unless ($options{bug}) {
        my $pwdFile = EBox::Config::conf() . 'samba.passwd';
        # Additional domain controllers does not have stashed pwd
        if (EBox::Sudo::fileTest('-f', $pwdFile)) {
            EBox::Sudo::root("cp '$pwdFile' $dir");
        }
    }
}

sub _usersInEtcPasswd
{
    my ($self) = @_;
    my @users;

    my @lines = File::Slurp::read_file('/etc/passwd');
    foreach my $line (@lines) {
        my ($user) = split ':', $line, 2;
        push @users, $user;
    }

    return \@users;
}

sub restoreDependencies
{
    my ($self) = @_;
    if ($self->mode() eq STANDALONE_MODE) {
            return ['dns'];
    }
    return [];
}

# Method: restoreBackupPreCheck
#
# Check that the backup to be restored mode is compatible.
# Also, in case we are using standalone mode, checks if we have clonflicts between
# users in the LDAP data to be loaded and the users in /etc/passwd
sub restoreBackupPreCheck
{
    my ($self, $dir) = @_;
    my $mode = $self->mode();
    my $backupModeFile = $dir . '/' . BACKUP_MODE_FILE;
    my $backupMode;
    if (-r $backupModeFile) {
        $backupMode =  File::Slurp::read_file($backupModeFile);
    } else {
        # standalone mode by default
        $backupMode = STANDALONE_MODE;
    }


    if ($mode ne $backupMode) {
        my $modeModel = $self->model('Mode');
        throw EBox::Exceptions::External(
            __x('Cannot restore users module bacuse is running in mode {mode} and the backup was made in mode {bpMode}',
                mode => $modeModel->modePrintableName($mode),
                bpMode => $modeModel->modePrintableName($backupMode),
               )
           );
    }

    if ($mode ne STANDALONE_MODE) {
        # nothing more to check
        return;
    }

    my $oldHostname;
    my $hostnameFile = "$dir/oldhostname";
    if (-r $hostnameFile) {
        $oldHostname = File::Slurp::read_file($hostnameFile);
    } 
    if ($oldHostname) {
        my $hostname  =  `hostname --fqdn`;
        chomp $hostname;
        if ($hostname ne $oldHostname) {
            throw EBox::Exceptions::External(
                __x('To be able to restore this backup the hostname should be first set to {hn}. Otherwise samba data could not be restored.',
                    hn => $oldHostname)
               );
        }
    } else {
        EBox::warn("No hostname stored in backup. Samba restore will fail if you dont have the same hostname that the original server");
    }

    my $userListFile = $dir . '/' . BACKUP_USERS_FILE;
    if (EBox::Sudo::fileTest('-f', $userListFile)) {
        my %etcPasswdUsers = map { $_ => 1 } @{ $self->_usersInEtcPasswd() };
        my @usersToRestore = File::Slurp::read_file($userListFile);
        foreach my $user (@usersToRestore) {
            chomp $user;
            if (exists $etcPasswdUsers{$user}) {
                throw EBox::Exceptions::External(
                    __x('Cannot restore because LDAP user {user} already ' .
                        'exists as /etc/passwd user. Delete or rename this ' .
                        'user and try again', user => $user));
            }
        }
    }
}

sub restoreConfig
{
    my ($self, $dir) = @_;
    my $mode = $self->mode();

    File::Slurp::write_file($dir . '/' . BACKUP_MODE_FILE, $mode);
    if ($mode ne STANDALONE_MODE) {
        # only standalone mode needs to do this operations to restore the LDAP
        # directory
        return;
    }

    my $modeDC = $self->dcMode();
    unless ($modeDC eq EBox::Samba::Model::DomainSettings::MODE_DC()) {
        # Restoring an ADC will corrupt entire domain as sync data
        # get out of sync.
        EBox::info(__("Restore is only possible if the server is the unique " .
                      "domain controller of the forest"));
        $self->getProvision->setProvisioned(0);
        return;
    }

    $self->stopService();

    # Remove private and sysvol
    my $privateDir = PRIVATE_DIR;
    my $sysvolDir = SYSVOL_DIR;
    EBox::Sudo::root("rm -rf $privateDir $sysvolDir");

    # Unpack sysvol and private
    my %dest = ( sysvol => $sysvolDir, private => $privateDir );
    foreach my $archive (keys %dest) {
        if (EBox::Sudo::fileTest('-f', "$dir/$archive.tar.bz2")) {
            my $destdir = dirname($dest{$archive});
            EBox::Sudo::root("tar jxfp $dir/$archive.tar.bz2 -C $destdir");
        }
    }

    # Rename ldb files
    my $ldbBakFiles = EBox::Sudo::root("find $privateDir -name '*.ldb.bak'");
    my $tdbBakFiles = EBox::Sudo::root("find $privateDir -name '*.tdb.bak'");
    foreach my $bakFile ((@{$ldbBakFiles}, @{$tdbBakFiles})) {
        chomp $bakFile;
        my $destFile = $bakFile;
        $destFile =~ s/\.bak$//;
        EBox::Sudo::root("mv '$bakFile' '$destFile'");
    }
    # Hard-link DomainDnsZones and ForestDnsZones partitions
    EBox::Sudo::root("rm -f $privateDir/dns/sam.ldb.d/DC*FORESTDNSZONES*");
    EBox::Sudo::root("rm -f $privateDir/dns/sam.ldb.d/DC*DOMAINDNSZONES*");
    EBox::Sudo::root("rm -f $privateDir/dns/sam.ldb.d/metadata.tdb");
    EBox::Sudo::root("ln $privateDir/sam.ldb.d/DC*FORESTDNSZONES* $privateDir/dns/sam.ldb.d/");
    EBox::Sudo::root("ln $privateDir/sam.ldb.d/DC*DOMAINDNSZONES* $privateDir/dns/sam.ldb.d/");
    EBox::Sudo::root("ln $privateDir/sam.ldb.d/metadata.tdb $privateDir/dns/sam.ldb.d/");
    EBox::Sudo::root("chown root:bind $privateDir/dns/*.ldb");
    EBox::Sudo::root("chmod 660 $privateDir/dns/*.ldb");

    # Restore stashed password
    if (EBox::Sudo::fileTest('-f', "$dir/samba.passwd")) {
        EBox::Sudo::root("cp $dir/samba.passwd " . EBox::Config::conf());
        EBox::Sudo::root("chmod 0600 $dir/samba.passwd");
    }

    # Set provisioned flag
    $self->getProvision->setProvisioned(1);

    $self->_startService();

    $self->getProvision()->resetSysvolACL();
}

sub _removePasswds
{
  my ($self, $file) = @_;

  my $anyPasswdAttr = any(qw(
              userPassword
              sambaLMPassword
              sambaNTPassword
              )
          );
  my $passwordSubstitution = "password";

  my $FH_IN;
  open $FH_IN, "<$file" or
      throw EBox::Exceptions::Internal ("Cannot open $file: $!");

  my ($FH_OUT, $tmpFile) = tempfile(DIR => EBox::Config::tmp());

  foreach my $line (<$FH_IN>) {
      my ($attr, $value) = split ':', $line;
      if ($attr eq $anyPasswdAttr) {
          $line = $attr . ': ' . $passwordSubstitution . "\n";
      }

      print $FH_OUT $line;
  }

  close $FH_IN  or
      throw EBox::Exceptions::Internal ("Cannot close $file: $!");
  close $FH_OUT or
      throw EBox::Exceptions::Internal ("Cannot close $tmpFile: $!");

  File::Copy::move($tmpFile, $file);
  unlink $tmpFile;
}

sub listSchemas
{
    my ($self, $ldap) = @_;

    my %args = (
        'base' => 'cn=schema,cn=config',
        'scope' => 'one',
        'filter' => "(objectClass=olcSchemaConfig)"
    );
    my $result = $ldap->search(%args);

    my @schemas = map { $_->get_value('cn') } $result->entries();
    return \@schemas;
}

sub mode
{
    my ($self) = @_;
    my $mode = $self->model('Mode')->value('mode');
    if (not $mode) {
        return STANDALONE_MODE;
    }
    return $mode;
}

# Method: dcMode
#
#   Returns the configured server mode
#
sub dcMode
{
    my ($self) = @_;

    my $model = $self->model('DomainSettings');
    return $model->modeValue();
}


# Method: newLDAP
#
#  Return a new LDAP object instance of the class requiered by the active mode
#
sub newLDAP
{
    my ($self) = @_;
    my $mode = $self->mode();
    if ($mode eq EXTERNAL_AD_MODE) {
        return EBox::LDAP::ExternalAD->instance(
            @{ $self->model('Mode')->adModeOptions() }
           );
    }

    return  EBox::Ldap->instance();
}

# common check for user names and group names
sub checkNameLimitations
{
    my ($name) = @_;

    # combination of unix limitations + windows limitation characters are
    # limited to unix portable file character + space for windows compability
    # slash not valid as first character (unix limitation)
    # see http://technet.microsoft.com/en-us/library/cc776019%28WS.10%29.aspx
    if ($name =~ /^[a-zA-Z0-9\._-][a-zA-Z0-9\._[:space:]-]*$/) {
         return 1;
     } else {
         return undef;
     }
}

# Method: checkCnLimitations
#
#   Return whether the given string is valid for its usage as a cn field.
#
# Parameters:
#
#   string - The string to check.
#
sub checkCnLimitations
{
    my ($self, $string) = @_;

    if ($string =~ /^([a-zA-Z\d\s_-]+\.)*[a-zA-Z\d\s_-]+$/) {
        return 1;
    } else {
        return undef;
    }
}

#  Nethod: newUserUidNumber
#
#  return the uid for a new user
#
#   Parameters:
#     system - true if we want the uid for a system user, defualt false
#
sub newUserUidNumber
{
    my ($self, $system) = @_;

    return EBox::Samba::User->_newUserUidNumber($system);
}

######################################
##  SysInfo observer implementation ##
######################################

# Method: hostNameChanged
#
#   Disallow domainname changes if module is configured
#
sub hostNameChanged
{
    my ($self, $oldHostName, $newHostName) = @_;

    $self->_hostOrDomainChanged();
}

# Method: hostNameChangedDone
#
#   This method updates the computer netbios name if the module has not
#   been configured yet
#
sub hostNameChangedDone
{
    my ($self, $oldHostName, $newHostName) = @_;

    my $settings = $self->global()->modInstance('samba')->model('DomainSettings');
    $settings->setValue('netbiosName', $newHostName);
}

# Method: hostDomainChanged
#
#   This method disallow the change of the host domain if the module is
#   configured (implies that the kerberos realm has been initialized)
#
sub hostDomainChanged
{
    my ($self, $oldDomainName, $newDomainName) = @_;

    $self->_hostOrDomainChanged();

    if ($self->configured()) {
        $self->set('need_reprovision', 1);
        $self->setAsChanged(1); # for compability with machines with phantom
                                # need_reprovision in read-only tree
        EBox::Global->modInstance('webadmin')->setAsChanged();
    }
}

# Method: hostDomainChangedDone
#
#   This method updates the base DN for LDAP if the module has not
#   been configured yet
#
sub hostDomainChangedDone
{
    my ($self, $oldDomainName, $newDomainName) = @_;

    unless ($self->configured()) {
        my $mode = $self->model('Mode');
        my $newDN = $mode->getDnFromDomainName($newDomainName);
        $mode->setValue('dn', $newDN);
    }

    my $settings = $self->global()->modInstance('samba')->model('DomainSettings');
    $settings->setValue('realm', uc ($newDomainName));

    my @parts = split (/\./, $newDomainName);
    my $value = substr($parts[0], 0, 15);
    $value = 'ZENTYAL-DOMAIN' unless defined $value;
    $value = uc ($value);
    $settings->setValue('workgroup', $value);
}

sub _hostOrDomainChanged
{
    my ($self) = @_;

    if ($self->configured()) {
        if ($self->_adcMode()) {
            throw EBox::Exceptions::UnwillingToPerform(
                reason => __('The hostname or domain cannot be changed if Zentyal is configured as additional domain controller.')
            );
        }

        $self->set('need_reprovision', 1);
    }
}


# Method: reprovision
#
#   Destroys all LDAP/Kerberos configuration and creates a new
#   empty one. Useful after a host/domain change.
#
sub reprovision
{
    my ($self) = @_;

    return unless $self->configured();
    EBox::info("Reprovisioning LDAP");

    my @removeHomeCmds;
    foreach my $home (map { $_->home() } @{$self->users()}) {
        push (@removeHomeCmds, "rm -rf $home");
    }
    EBox::Sudo::root(@removeHomeCmds);

    $self->_manageService('stop');
    EBox::Sudo::root('rm -rf /var/lib/ldap/*');
    $self->_manageService('start');

    $self->enableActions();

    # LDAP module has lost its schemas and LDAP config after the reprovision
    my $global = $self->global();
    my @mods = @{ $global->sortModulesByDependencies($global->modInstances(), 'depends' ) };
    foreach my $mod (@mods) {
        if (not $mod->isa('EBox::Module::LDAP')) {
            next;
        } elsif ($mod->name() eq $self->name()) {
            # dont reconfigure itself
            next;
        } elsif (not $mod->configured()) {
            next;
        }
        $mod->reprovisionLDAP();
    }
}

sub reprovisionLDAP
{
    throw EBox::Exceptions::Internal("This method should not be called in user module");
}

# Implement EBox::SyncFolders::Provider interface
sub syncFolders
{
    my ($self) = @_;

    # sync all shares
    my $sshares = $self->model('SyncShares');
    my $shares = $self->model('SambaShares');

    my $syncAll = $sshares->row()->valueByName('sync');
    my @folders;
    for my $id (@{$shares->enabledRows()}) {
        my $row = $shares->row($id);
        my $sync = $row->valueByName('sync');

        my $path = $row->elementByName('path');
        if ($path->selectedType() eq 'zentyal') {
            $path = SHARES_DIR . '/' . $path->value();
        } else {
            $path = $path->value();
        }

        if ($sync or $syncAll) {
            push (@folders, new EBox::SyncFolders::Folder($path, 'share', name => basename($path)));
        }
    }

    if ($self->recoveryEnabled()) {
        push (@folders, new EBox::SyncFolders::Folder('/home', 'recovery'));
        foreach my $share ($self->filesystemShares()) {
            push (@folders, new EBox::SyncFolders::Folder($share, 'recovery'));
        }
    }

    return \@folders;
}

sub recoveryDomainName
{
    return __('Users data and Filesystem shares');
}

# Method: entryModeledObject
#
#   Return the Perl Object that handles the given LDAP entry.
#
#   Throw EBox::Exceptions::Internal on error.
#
# Parameters:
#
#   entry - A Net::LDAP::Entry object.
#
sub entryModeledObject
{
    my ($self, $entry) = @_;

    my $anyObjectClasses = any(@{[$entry->get_value('objectClass')]});
    # IMPORTANT: The order matters, a contactClass would match users too, so we must check first if it's a user.
    foreach my $type ( qw(ouClass userClass contactClass groupClass containerClass)) {
        my $class = $self->$type();
        # containerClass may not exist.
        next unless ($class);
        my $mainLDAPClass = $class->mainObjectClass();
        if ((defined $mainLDAPClass) and ($mainLDAPClass eq $anyObjectClasses)) {
            return $class->new(entry => $entry);
        }
    }

    my $ldap = $self->ldap();
    if ($entry->dn() eq $ldap->dn()) {
        return $self->defaultNamingContext();
    }

    EBox::debug("Ignored unknown perl object for DN: " . $entry->dn());
    return undef;
}

# Method: relativeDN
#
#   Return the given dn without the naming Context part.
#
sub relativeDN
{
    my ($self, $dn) = @_;

    throw EBox::Exceptions::MissingArgument("dn") unless ($dn);

    my $baseDN = $self->ldap()->dn();

    return '' if ($dn eq $baseDN);

    if (not $dn =~ s/,$baseDN$//) {
        throw EBox::Exceptions::Internal("$dn is not contained in $baseDN");
    }

    return $dn;
}

# Method: objectFromDN
#
#   Return the perl object modeling the given dn or undef if not found.
#
# Parameters:
#
#   dn - An LDAP DN string identifying the object to retrieve.
#
sub objectFromDN
{
    my ($self, $dn) = @_;
    my $ldap = $self->ldap();
    if ($dn eq $ldap->dn()) {
        return $self->defaultNamingContext();
    }

    my $baseObject = new EBox::Samba::LdapObject(dn => $dn);

    if ($baseObject->exists()) {
        return $self->entryModeledObject($baseObject->_entry());
    } else {
        return undef;
    }
}

# Method: defaultNamingContext
#
#   Return the Perl Object that holds the default Naming Context for this LDAP server.
#
sub defaultNamingContext
{
    my ($self) = @_;

    my $ldap = $self->ldap;
    return new EBox::Samba::NamingContext(dn => $ldap->dn());
}

sub ousToHide
{
    my ($self) = @_;

    my @ous;

    foreach my $mod (@{EBox::Global->modInstancesOfType('EBox::Module::LDAP')}) {
        push (@ous, @{$mod->_ldapModImplementation()->hiddenOUs()});
    }

    return \@ous;
}

# Method: checkMailNotInUse
#
#   check if a mail address is not used by the system and throw exception if it
#   is already used
#
#   If mail module is installed its checkMailNotInUse method should be called
#   instead this one
sub checkMailNotInUse
{
    my ($self, $addr, %params) = @_;

    my %searchParams = (
        base => $self->ldap()->dn(),
        filter => "&(|(objectclass=person)(objectclass=couriermailalias)(objectclass=group))(|(otherMailbox=$addr)(mail=$addr))",
        scope => 'sub'
    );

    my $result = $self->{'ldap'}->search(\%searchParams);
    foreach my $entry ($result->entries()) {
        my $modeledObject = $self->entryModeledObject($entry);
        my $type = $modeledObject ? $modeledObject->printableType() : $entry->get_value('objectClass');
        my $name;
        if ($type eq 'CourierMailAlias') {
            $type = __('alias');
            $name = $entry->get_value('mail');
        } else {
            $name = $modeledObject ? $modeledObject->name() : $entry->dn();
        }

        my $ownAddress = 0;
        if ($params{owner}) {
            $ownAddress = $entry->dn() eq $params{owner}->dn();
        }
        if (not $ownAddress) {
            EBox::Exceptions::External->throw(__x('Address {addr} is already in use by the {type} {name}',
                                              addr => $addr,
                                              type => $type,
                                              name => $name,
                                        ),
                                    );
        }
    }
}

sub getProvision
{
    my ($self) = @_;

    unless (defined $self->{provision}) {
        $self->{provision} = new EBox::Samba::Provision();
    }
    return $self->{provision};
}

sub isProvisioned
{
    my ($self) = @_;

    return $self->getProvision->isProvisioned();
}

# Method: domainControllers
#
#   Query the domain controllers by searching in 'Domain Controllers' OU
#
# Returns:
#
#   Array reference containing instances of EBox::Samba::Computer class
#
sub domainControllers
{
    my ($self) = @_;

    return [] unless $self->isProvisioned();

    my $sort = new Net::LDAP::Control::Sort(order => 'name');
    my $ldap = $self->ldap();
    my $baseDN = $ldap->dn();
    my $args = {
        base => "OU=Domain Controllers,$baseDN",
        filter => 'objectClass=computer',
        scope => 'sub',
        control => [ $sort ],
    };

    my $result = $ldap->search($args);

    my @computers;
    foreach my $entry ($result->entries()) {
        my $computer = new EBox::Samba::Computer(entry => $entry);
        next unless $computer->exists();
        push (@computers, $computer);
    }

    return \@computers;
}

# Method: computers
#
#   Query the computers joined to the domain by searching in the computers
#   container
#
# Returns:
#
#   Array reference containing instances of EBox::Samba::Computer class
#
sub computers
{
    my ($self) = @_;

    return [] unless $self->isProvisioned();

    my $sort = new Net::LDAP::Control::Sort(order => 'name');
    my $ldap = $self->ldap();
    my $baseDN = $ldap->dn();
    my $args = {
        base => "CN=Computers,$baseDN",,
        filter => 'objectClass=computer',
        scope => 'sub',
        control => [ $sort ],
    };

    my $result = $self->ldap->search($args);

    my @computers;
    foreach my $entry ($result->entries()) {
        my $computer = new EBox::Samba::Computer(entry => $entry);
        next unless $computer->exists();
        push (@computers, $computer);
    }

    return \@computers;
}

# Method: defaultNetbios
#
#   Generates the default netbios server name
#
sub defaultNetbios
{
    my ($self) = @_;

    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $hostName = $sysinfo->hostName();
    $hostName = substr($hostName, 0, 15);

    return $hostName;
}

# Method: defaultWorkgroup
#
#   Generates the default workgroup
#
sub defaultWorkgroup
{
    my $users = EBox::Global->modInstance('samba');
    my $realm = $users->kerberosRealm();
    my @parts = split (/\./, $realm);
    my $value = substr($parts[0], 0, 15);
    $value = 'ZENTYAL-DOMAIN' unless defined $value;

    return uc($value);
}

# Method: defaultDescription
#
#   Generates the default server string
#
sub defaultDescription
{
    my $prefix = EBox::Config::configkey('custom_prefix');
    $prefix = 'zentyal' unless $prefix;

    return ucfirst($prefix) . ' Server';
}

sub writeSambaConfig
{
    my ($self) = @_;

    my $netbiosName = $self->netbiosName();
    my $realmName   = $self->kerberosRealm();

    my $sysinfo = EBox::Global->modInstance('sysinfo');
    my $hostDomain = $sysinfo->hostDomain();

    my @array = ();
    push (@array, 'workgroup'   => $self->workgroup());
    push (@array, 'netbiosName' => $netbiosName);
    push (@array, 'description' => $self->description());
    push (@array, 'mode'        => 'dc');
    push (@array, 'realm'       => $realmName);
    push (@array, 'domain'      => $hostDomain);
    push (@array, 'roamingProfiles' => $self->roamingProfiles());
    push (@array, 'profilesPath' => PROFILES_DIR);
    push (@array, 'sysvolPath'  => SYSVOL_DIR);
    push (@array, 'shares' => 1);

    if ($self->global()->modExists('openchange')) {
        my $openchangeMod = $self->global()->modInstance('openchange');
        if ($openchangeMod->isEnabled() and $openchangeMod->isProvisioned()) {
            push (@array, 'openchange' => 1);
            $openchangeMod->writeSambaConfig();
        }
    }

    if ($self->global()->modExists('printers')) {
        my $printersMod = $self->global()->modInstance('printers');
        if ($printersMod->isEnabled()) {
            push (@array, 'print' => 1);
            $printersMod->writeSambaConfig();
        }
    }

    $self->writeConfFile(SAMBACONFFILE, 'samba/smb.conf.mas', \@array,
                         { 'uid' => 'root', 'gid' => 'root', mode => '644' });

    my $prefix = EBox::Config::configkey('custom_prefix');
    $prefix = 'zentyal' unless $prefix;

    push (@array, 'prefix' => $prefix);
    push (@array, 'disableFullAudit' => EBox::Config::boolean('disable_fullaudit'));
    push (@array, 'unmanagedAcls' => EBox::Config::boolean('unmanaged_acls'));
    push (@array, 'shares' => $self->shares());

    push (@array, 'antivirus' => $self->defaultAntivirusSettings());
    push (@array, 'antivirus_exceptions' => $self->antivirusExceptions());
    push (@array, 'antivirus_config' => $self->antivirusConfig());
    push (@array, 'recycle' => $self->defaultRecycleSettings());
    push (@array, 'recycle_exceptions' => $self->recycleExceptions());
    push (@array, 'recycle_config' => $self->recycleConfig());

    $self->_writeAntivirusConfig();

    $self->writeConfFile(SHARESCONFFILE, 'samba/shares.conf.mas', \@array,
                         { 'uid' => 'root', 'gid' => 'root', mode => '644' });
}

# Method: netbiosName
#
#   Returns the configured netbios name
#
sub netbiosName
{
    my ($self) = @_;

    my $model = $self->model('DomainSettings');
    return $model->netbiosNameValue();
}

# Method: workgroup
#
#   Returns the configured workgroup name
#
sub workgroup
{
    my ($self) = @_;

    my $model = $self->model('DomainSettings');
    return $model->workgroupValue();
}

# Method: description
#
#   Returns the configured description string
#
sub description
{
    my ($self) = @_;

    my $model = $self->model('DomainSettings');
    return $model->descriptionValue();
}

# Method: roamingProfiles
#
#   Returns if roaming profiles are enabled
#
sub roamingProfiles
{
    my ($self) = @_;

    my $model = $self->model('DomainSettings');
    return $model->roamingValue();
}

# Method: drive
#
#   Returns the configured drive letter
#
sub drive
{
    my ($self) = @_;

    my $model = $self->model('DomainSettings');
    return $model->driveValue();
}

# Method: dMD
#
#   Return the Perl Object that holds the Directory Management Domain for this LDB server.
#
sub dMD
{
    my ($self) = @_;

    my $dn = "CN=Schema,CN=Configuration," . $self->ldap()->dn();
    return new EBox::Samba::DMD(dn => $dn);
}

# Method: gpos
#
#   Returns the Domain GPOs
#
# Returns:
#
#   Array ref containing instances of EBox::Samba::GPO
#
sub gpos
{
    my ($self) = @_;

    my $gpos = [];
    my $defaultNC = $self->ldap->dn();
    my $params = {
        base => "CN=Policies,CN=System,$defaultNC",
        scope => 'one',
        filter => '(objectClass=GroupPolicyContainer)',
        attrs => ['*']
    };
    my $result = $self->ldap->search($params);
    foreach my $entry ($result->entries()) {
        push (@{$gpos}, new EBox::Samba::GPO(entry => $entry));
    }

    return $gpos;
}

# Method: shares
#
#   It returns the custom shares
#
# Returns:
#
#   Array ref containing hash ref with:
#
#   share   - share's name
#   path    - share's path
#   comment - share's comment
#   readOnly  - string containing users and groups with read-only permissions
#   readWrite - string containing users and groups with read and write
#               permissions
#   administrators  - string containing users and groups with admin priviliges
#                     on the share
#   validUsers - readOnly + readWrite + administrators
#
sub shares
{
    my ($self) = @_;

    my $shares = $self->model('SambaShares');
    my @shares = ();

    for my $id (@{$shares->enabledRows()}) {
        my $row = $shares->row($id);
        my @readOnly;
        my @readWrite;
        my @administrators;
        my $shareConf = {};

        my $path = $row->elementByName('path');
        if ($path->selectedType() eq 'zentyal') {
            $shareConf->{'path'} = SHARES_DIR . '/' . $path->value();
        } else {
            $shareConf->{'path'} = $path->value();
        }
        $shareConf->{'type'} = $path->selectedType();
        $shareConf->{'share'} = $row->valueByName('share');
        $shareConf->{'comment'} = $row->valueByName('comment');
        $shareConf->{'guest'} = $row->valueByName('guest');
        $shareConf->{'groupShare'} = $row->valueByName('groupShare');

        for my $subId (@{$row->subModel('access')->ids()}) {
            my $subRow = $row->subModel('access')->row($subId);
            my $userType = $subRow->elementByName('user_group');
            my $preCar = '';
            if ($userType->selectedType() eq 'group') {
                $preCar = '@';
            }
            my $user =  $preCar . '"' . $userType->printableValue() . '"';

            my $permissions = $subRow->elementByName('permissions');

            if ($permissions->value() eq 'readOnly') {
                push (@readOnly, $user);
            } elsif ($permissions->value() eq 'readWrite') {
                push (@readWrite, $user);
            } elsif ($permissions->value() eq 'administrator') {
                push (@administrators, $user)
            }
        }

        $shareConf->{'readOnly'} = join (', ', @readOnly);
        $shareConf->{'readWrite'} = join (', ', @readWrite);
        $shareConf->{'administrators'} = join (', ', @administrators);
        $shareConf->{'validUsers'} = join (', ', @readOnly,
                                                 @readWrite,
                                                 @administrators);

        push (@shares, $shareConf);
    }

    return \@shares;
}

sub defaultAntivirusSettings
{
    my ($self) = @_;

    my $antivirus = $self->model('AntivirusDefault');
    return $antivirus->value('scan');
}

sub antivirusExceptions
{
    my ($self) = @_;

    my $model = $self->model('AntivirusExceptions');
    my $exceptions = {
        'share' => {},
        'group' => {},
    };

    foreach my $id (@{$model->ids()}) {
        my $row = $model->row($id);
        my $element = $row->elementByName('user_group_share');
        my $type = $element->selectedType();
        if ($type eq 'users') {
            $exceptions->{'users'} = 1;
        } else {
            my $value = $element->printableValue();
            $exceptions->{$type}->{$value} = 1;
        }
    }

    return $exceptions;
}

sub antivirusConfig
{
    my ($self) = @_;

    # Provide a default config and override with the conf file if exists
    my $avModel = $self->model('AntivirusDefault');
    my $conf = {
        show_special_files       => 'True',
        rm_hidden_files_on_rmdir => 'True',
        recheck_time_open        => '50',
        recheck_tries_open       => '100',
        allow_nonscanned_files   => 'False',
    };

    foreach my $key (keys %{$conf}) {
        my $value = EBox::Config::configkey($key);
        $conf->{$key} = $value if $value;
    }

    # Hard coded settings
    $conf->{quarantine_dir} = $avModel->QUARANTINE_DIR();
    $conf->{domain_socket}  = 'True';
    $conf->{socketname}     = $avModel->ZAVS_SOCKET();

    return $conf;
}

sub defaultRecycleSettings
{
    my ($self) = @_;

    my $recycle = $self->model('RecycleDefault');
    return $recycle->row()->valueByName('enabled');
}

sub recycleExceptions
{
    my ($self) = @_;

    my $model = $self->model('RecycleExceptions');
    my $exceptions = {
        'share' => {},
        'group' => {},
    };

    for my $id (@{$model->ids()}) {
        my $row = $model->row($id);
        my $element = $row->elementByName('user_group_share');
        my $type = $element->selectedType();
        if ($type eq 'users') {
            $exceptions->{'users'} = 1;
        } else {
            my $value = $element->printableValue();
            $exceptions->{$type}->{$value} = 1;
        }
    }
    return $exceptions;
}

sub recycleConfig
{
    my ($self) = @_;

    my $conf = {};
    my @keys = ('repository', 'directory_mode', 'keeptree', 'versions', 'touch', 'minsize',
                'maxsize', 'exclude', 'excludedir', 'noversions', 'inherit_nt_acl');

    foreach my $key (@keys) {
        my $value = EBox::Config::configkey($key);
        if ($value) {
            $conf->{$key} = $value;
        }
    }

    return $conf;
}

sub _writeDnsUpdateList
{
    my ($self) = @_;

    my $array = [];
    my $partitions = ['DomainDnsZones', 'ForestDnsZones'];
    push (@{$array}, partitions => $partitions);
    $self->writeConfFile(SAMBA_DNS_UPDATE_LIST,
                         'samba/dns_update_list.mas', $array,
                         { 'uid' => '0', 'gid' => '0', mode => '644' });
}

sub _writeAntivirusConfig
{
    my ($self) = @_;

    return unless EBox::Global->modExists('antivirus');

    my $avModule = EBox::Global->modInstance('antivirus');
    my $avModel = $self->model('AntivirusDefault');

    my $conf = {};
    $conf->{clamavSocket} = $avModule->CLAMD_SOCKET();
    $conf->{quarantineDir} = $avModel->QUARANTINE_DIR();
    $conf->{zavsSocket}  = $avModel->ZAVS_SOCKET();
    $conf->{nThreadsConf} = EBox::Config::configkey('scanning_threads');

    write_file(ANTIVIRUS_CONF, encode_json($conf));
}

sub _setupQuarantineDirectory
{
    my ($self) = @_;

    my $zentyalUser = EBox::Config::user();
    my $guest       = $self->ldap->domainGuestUser();
    my $guestUidNumber = $guest->uidNumber();
    my $avModel     = $self->model('AntivirusDefault');
    my $quarantine  = $avModel->QUARANTINE_DIR();
    my @cmds;
    push (@cmds, "mkdir -p '$quarantine'");
    push (@cmds, "chown -R $zentyalUser.adm '$quarantine'");
    push (@cmds, "chmod 770 '$quarantine'");
    push (@cmds, "setfacl -R -m u:$guestUidNumber:rwx g:adm:rwx '$quarantine'");

    # Grant access to domain admins
    my $domainAdminsSid = $self->ldap->domainSID() . '-512';
    my $domainAdminsGroup = new EBox::Samba::Group(sid => $domainAdminsSid);
    if ($domainAdminsGroup->exists()) {
        my @domainAdmins = $domainAdminsGroup->get('member');
        foreach my $memberDN (@domainAdmins) {
            my $user = new EBox::Samba::User(dn => $memberDN);
            if ($user->exists()) {
                my $uid = $user->get('samAccountName');
                push (@cmds, "setfacl -m u:$uid:rwx '$quarantine'");
            }
        }
    }
    EBox::Sudo::silentRoot(@cmds);
}

# Implement LogHelper interface
sub tableInfo
{
    my ($self) = @_;

    my $access_titles = {
        'timestamp' => __('Date'),
        'client' => __('Client address'),
        'username' => __('User'),
        'event' => __('Action'),
        'resource' => __('Resource'),
    };
    my @access_order = qw(timestamp client username event resource);
    my $access_events = {
        'connect' => __('Connect'),
        'opendir' => __('Access to directory'),
        'readfile' => __('Read file'),
        'writefile' => __('Write file'),
        'disconnect' => __('Disconnect'),
        'unlink' => __('Remove'),
        'mkdir' => __('Create directory'),
        'rmdir' => __('Remove directory'),
        'rename' => __('Rename'),
    };

    my $virus_titles = {
        'timestamp' => __('Date'),
        'client' => __('Client address'),
        'username' => __('User'),
        'filename' => __('File name'),
        'virus' => __('Virus'),
        'event' => __('Type'),
    };
    my @virus_order = qw(timestamp client username filename virus event);;
    my $virus_events = { 'virus' => __('Virus') };

    my $quarantine_titles = {
        'timestamp' => __('Date'),
        'client' => __('Client address'),
        'username' => __('User'),
        'filename' => __('File name'),
        'qfilename' => __('Quarantined file name'),
        'event' => __('Quarantine'),
    };
    my @quarantine_order = qw(timestamp client username filename qfilename event);
    my $quarantine_events = { 'quarantine' => __('Quarantine') };

    return [{
        'name' => __('Samba access'),
        'tablename' => 'samba_access',
        'titles' => $access_titles,
        'order' => \@access_order,
        'timecol' => 'timestamp',
        'filter' => ['client', 'username', 'resource'],
        'types' => { 'client' => 'IPAddr' },
        'events' => $access_events,
        'eventcol' => 'event'
    },
    {
        'name' => __('Samba virus'),
        'tablename' => 'samba_virus',
        'titles' => $virus_titles,
        'order' => \@virus_order,
        'timecol' => 'timestamp',
        'filter' => ['client', 'filename', 'virus'],
        'types' => { 'client' => 'IPAddr' },
        'events' => $virus_events,
        'eventcol' => 'event'
    },
    {
        'name' => __('Samba quarantine'),
        'tablename' => 'samba_quarantine',
        'titles' => $quarantine_titles,
        'order' => \@quarantine_order,
        'timecol' => 'timestamp',
        'filter' => ['filename'],
        'types' => { 'client' => 'IPAddr' },
        'events' => $quarantine_events,
        'eventcol' => 'event'
    }];
}

sub logHelper
{
    my ($self) = @_;

    return (new EBox::SambaLogHelper);
}

# Method: filesystemShares
#
#   This function is used for Disaster Recovery, to get
#   the paths of the filesystem shares.
#
sub filesystemShares
{
    my ($self) = @_;

    my $shares = $self->shares();
    my $paths = [];

    foreach my $share (@{$shares}) {
        if ($share->{type} eq 'system') {
            push (@{$paths}, $share->{path});
        }
    }

    return $paths;
}

# Method: userShares
#
#   This function is used to generate disk usage reports. It
#   returns all the users with their shares
#
#   Returns:
#       Array ref with hash refs containing:
#           - 'user' - String the username
#           - 'shares' - Array ref with all the shares for this user
#
sub userShares
{
    my ($self) = @_;

    my $userProfilesPath = PROFILES_DIR;

    my $users = $self->users();

    my $shares = [];
    foreach my $user (@{$users}) {
        my $userProfilePath = $userProfilesPath . "/" . $user->get('samAccountName');

        my $userShareInfo = {
            'user' => $user->name(),
            'shares' => [$user->get('homeDirectory'), $userProfilePath],
        };
        push (@{$shares}, $userShareInfo);
    }

    return $shares;
}

# Method: groupPaths
#
#   This function is used to generate disk usage reports. It
#   returns the group share path if it is configured.
#
sub groupPaths
{
    my ($self, $group) = @_;

    my $groupName = $group->get('cn');
    my $shares = $self->shares();
    my $paths = [];

    foreach my $share (@{$shares}) {
        if (defined $groupName and defined $share->{groupShare} and
            $groupName eq $share->{groupShare}) {
            push (@{$paths}, $share->{path});
            last;
        }
    }

    return $paths;
}

my @sharesSortedByPathLen;

sub _updatePathsByLen
{
    my ($self) = @_;

    @sharesSortedByPathLen = ();

    # Group and custom shares
    foreach my $sh_r (@{ $self->shares() }) {
        push @sharesSortedByPathLen, {path => $sh_r->{path},
                                      share =>  $sh_r->{share},
                                      type => ($sh_r->{'groupShare'} ? 'Group' : 'Custom')};
    }

    # User shares
    foreach my $user (@{ $self->userShares() }) {
        foreach my $share (@{$user->{'shares'}}) {
            my $entry = {};
            $entry->{'share'} = $user->{'user'};
            $entry->{'type'} = 'User';
            $entry->{'path'} = $share;
            push (@sharesSortedByPathLen, $entry);
        }
    }

    # add regexes
    foreach my $share (@sharesSortedByPathLen) {
        my $path = $share->{path};
        # Remove duplicate '/'
        $path =~ s/\/+/\//g;
        $share->{pathRegex} = qr{^$path/};
    }

    @sharesSortedByPathLen = sort {
        length($b->{path}) <=>  length($a->{path})
    } @sharesSortedByPathLen;
}

#   Returns a hash with:
#       share - The name of the share
#       path  - The path of the share
#       type  - The type of the share (User, Group, Custom)
sub shareByFilename
{
    my ($self, $filename) = @_;

    if (not @sharesSortedByPathLen) {
        $self->_updatePathsByLen();
    }

    foreach my $shareAndPath (@sharesSortedByPathLen) {
        if ($filename =~ m/$shareAndPath->{pathRegex}/) {
            return $shareAndPath;
        }
    }

    return undef;
}

# Method: hiddenSid
#
#   Check if the specified LDB object belongs to the list of regexps
#   of SIDs to hide on the UI read from /etc/zentyal/sids-to-hide.regex
#
sub hiddenSid
{
    my ($self, $object) = @_;

    unless (defined $object) {
        throw EBox::Exceptions::MissingArgument('object');
    }

    unless ($object->can('sid')) {
        return 0;
    }

    unless ($self->{sidsToHide}) {
        $self->{sidsToHide} = $self->_sidsToHide();
    }

    foreach my $ignoredSidMask (@{$self->{sidsToHide}}) {
       return 1 if ($object->sid() =~ m/$ignoredSidMask/);
    }

    return 0;
}

sub _sidsToHide
{
    my ($self) = @_;

    my $ignoredSidsFile = EBox::Config::etc() . 'sids-to-hide.regex';
    my @lines = read_file($ignoredSidsFile);
    my @sidsTmp = grep(/^\s*S-/, @lines);
    my @sids = map { s/\n//; $_; } @sidsTmp;

    return \@sids;
}

sub _cleanModulesForReprovision
{
    my ($self) = @_;

    foreach my $mod (@{$self->global()->modInstancesOfType('EBox::Module::LDAP')}) {
        my $state = $mod->get_state();
        delete $state->{'_schemasAdded'};
        delete $state->{'_ldapSetup'};
        $mod->set_state($state);
        $mod->setAsChanged(1);
    }
}

#
# EBox::NetworkObserver implementation
#

# Method: nameserverAdded
#
#   Overrided to clear LDAP connection if nameserver is added
#
# Overrides:
#
#   EBox::NetworkObserver::nameserverAdded
#
sub nameserverAdded
{
    my ($self, $ns, $iface) = @_;

    my $mode = $self->mode();
    if ($mode eq EXTERNAL_AD_MODE) {
        $self->clearLdapConn();
        $self->setAsChanged();
    }

    return 0;
}

# Method: nameserverDelete
#
#   Overrided to clear LDAP connection if nameserver is deleted
#
# Overrides:
#
#   EBox::NetworkObserver::nameserverDelete
#
sub nameserverDelete
{
    my ($self, $ns, $iface) = @_;

    my $mode = $self->mode();
    if ($mode eq EXTERNAL_AD_MODE) {
        $self->clearLdapConn();
        $self->setAsChanged();
    }

    return 0;
}

1;
