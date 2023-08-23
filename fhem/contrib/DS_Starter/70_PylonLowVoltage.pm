#########################################################################################################################
# $Id$
#########################################################################################################################
#
# 70_PylonLowVoltage.pm
#
# A FHEM module to read BMS values from Pylontech Low Voltage LiFePo04 batteries.
#
# This module is based on 70_Pylontech.pm written 2019 by Harald Schmitz.
# Code further development and extensions (c) 2023 by Heiko Maaz  e-mail: Heiko dot Maaz at t-online dot de
#
# Credits to FHEM user: satprofi, Audi_Coupe_S, abc2006
#
#########################################################################################################################
# Copyright notice
#
# (c) 2019 Harald Schmitz (70_Pylontech.pm)
# (c) 2023 Heiko Maaz
#
# This script is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# The GNU General Public License can be found at
# http://www.gnu.org/copyleft/gpl.html.
#
# This script is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# This copyright notice MUST APPEAR in all copies of the script!
#
#########################################################################################################################
# Forumlinks:
# https://forum.fhem.de/index.php?topic=117466.0  (Source of module 70_Pylontech.pm)
# https://forum.fhem.de/index.php?topic=126361.0
# https://forum.fhem.de/index.php?topic=112947.0
# https://forum.fhem.de/index.php?topic=32037.0
#
# Photovoltaik Forum:
# https://www.photovoltaikforum.com/thread/130061-pylontech-us2000b-daten-protokolle-programme
#
#########################################################################################################################
#
#  Leerzeichen entfernen: sed -i 's/[[:space:]]*$//' 70_PylonLowVoltage.pm
#
#########################################################################################################################
package FHEM::PylonLowVoltage;                                     ## no critic 'package'

use strict;
use warnings;
use GPUtils qw(GP_Import GP_Export);                               # wird für den Import der FHEM Funktionen aus der fhem.pl benötigt
use Time::HiRes qw(gettimeofday ualarm);
use IO::Socket::INET;
use Errno qw(ETIMEDOUT EWOULDBLOCK);
use Scalar::Util qw(looks_like_number);
use Carp qw(croak carp);

eval "use FHEM::Meta;1"          or my $modMetaAbsent = 1;         ## no critic 'eval'
eval "use IO::Socket::Timeout;1" or my $iostAbsent    = 1;         ## no critic 'eval'

use FHEM::SynoModules::SMUtils qw(moduleVersion);                  # Hilfsroutinen Modul

no if $] >= 5.017011, warnings => 'experimental::smartmatch';

# Run before module compilation
BEGIN {
  # Import from main::
  GP_Import(
      qw(
          AttrVal
          AttrNum
          data
          defs
          fhemTimeLocal
          fhem
          FmtTime
          FmtDateTime
          init_done
          InternalTimer
          IsDisabled
          Log
          Log3
          modules
          parseParams
          readingsSingleUpdate
          readingsBulkUpdate
          readingsBulkUpdateIfChanged
          readingsBeginUpdate
          readingsDelete
          readingsEndUpdate
          ReadingsAge
          ReadingsNum
          ReadingsTimestamp
          ReadingsVal
          RemoveInternalTimer
          readingFnAttributes
        )
  );

  # Export to main context with different name
  #     my $pkg  = caller(0);
  #     my $main = $pkg;
  #     $main =~ s/^(?:.+::)?([^:]+)$/main::$1\_/g;
  #     foreach (@_) {
  #         *{ $main . $_ } = *{ $pkg . '::' . $_ };
  #     }
  GP_Export(
      qw(
          Initialize
        )
  );
}

# Versions History intern (Versions history by Heiko Maaz)
my %vNotesIntern = (
  "0.1.3"  => "22.08.2023 improve responseCheck and others ",
  "0.1.2"  => "20.08.2023 commandref revised, analogValue -> use 'user defined items', refactoring according PBP ",
  "0.1.1"  => "16.08.2023 integrate US3000C, add print request command in HEX to Logfile, attr timeout ".
                          "change validation of received data, change DEF format, extend evaluation of chargeManagmentInfo ".
                          "add evaluate systemParameters, additional own values packImbalance, packState ",
  "0.1.0"  => "12.08.2023 initial version, switch to perl package, attributes: disable, interval, add command hashes ".
                          "get ... data command, add meta support and version management, more code changes ",
);

## Konstanten
###############
my $invalid     = 'unknown';                                         # default value for invalid readings
my $definterval = 30;                                                # default Abrufintervall der Batteriewerte
my $defto       = 0.5;                                               # default connection Timeout zum RS485 Gateway
my @blackl      = qw(state nextCycletime);                           # Ausnahmeliste deleteReadingspec

# Steuerhashes
###############
my %hrtnc = (                                                        # RTN Codes
  '00' => { desc => 'normal'                  },                     # normal Code
  '01' => { desc => 'VER error'               },
  '02' => { desc => 'CHKSUM error'            },
  '03' => { desc => 'LCHKSUM error'           },
  '04' => { desc => 'CID2 invalidation error' },
  '05' => { desc => 'Command format error'    },
  '06' => { desc => 'invalid data error'      },
  '90' => { desc => 'ADR error'               },
  '91' => { desc => 'Communication error between Master and Slave Pack'                                  },
  '98' => { desc => 'insufficient response length <LEN> of minimum length <MLEN> received ... discarded' },
  '99' => { desc => 'invalid data received ... discarded'                                                },
);

##################################################################################################################################################################
# The Basic data format SOI (7EH, ASCII '~') and EOI (CR -> 0DH) are explained and transferred in hexadecimal, 
# the other items are explained in hexadecimal and transferred by hexadecimal-ASCII, each byte contains two 
# ASCII, e.g. CID2 4BH transfer 2byte: 
# 34H (the ASCII of ‘4’) and 42H(the ASCII of ‘B’).
#
# HEX-ASCII converter: https://www.rapidtables.com/convert/number/ascii-hex-bin-dec-converter.html
# Modulo Rechner: https://miniwebtool.com/de/modulo-calculator/
# Pylontech Dokus: https://github.com/Interster/PylonTechBattery
##################################################################################################################################################################
#
# request command für '1': ~20024693E00202FD2D + CR
# command (HEX):           7e 32 30 30 32 34 36 39 33 45 30 30 32 30 32, 46 44 32 44 0d
# ADR: n=Batterienummer (2-x), m=Group Nr. (0-8), ADR = 0x0n + (0x10 * m) -> f. Batterie 1 = 0x02 + (0x10 * 0) = 0x02
# CID1: Kommando spezifisch, hier 46H
# CID2: Kommando spezifisch, hier 93H
# LENGTH: LENID + LCHKSUM -> Pylon LFP V2.8 Doku
# INFO: muß hier mit ADR übereinstimmen
# CHKSUM: 32+30+30+32+34+36+39+33+45+30+30+32+30+32 = 02D3H -> modulo 65536 = 02D3H -> bitweise invert = 1111 1101 0010 1100 -> +1 = 1111 1101 0010 1101 -> FD2DH
# 
# SOI  VER    ADR   CID1  CID2      LENGTH     INFO    CHKSUM
#  ~    20    02      46    93     E0    02    02      FD   2D
# 7E  32 30  30 32  34 36 39 33  45 30 30 32  30 32  46 44 32 44
#
my %hrsnb = (                                                        # Codierung Abruf serialNumber, mlen = Mindestlänge Antwortstring                    
  1 => { cmd => "~20024693E00202FD2D\x{0d}", mlen => 52 },
  2 => { cmd => "~20034693E00203FD2B\x{0d}", mlen => 52 },
  3 => { cmd => "~20044693E00204FD29\x{0d}", mlen => 52 },
  4 => { cmd => "~20054693E00205FD27\x{0d}", mlen => 52 },
  5 => { cmd => "~20064693E00206FD25\x{0d}", mlen => 52 },
  6 => { cmd => "~20074693E00207FD23\x{0d}", mlen => 52 },
);

# request command für '1': ~20024651E00202FD33 + CR
# command (HEX):           7e 32 30 30 32 34 36 35 31 45 30 30 32 30 32 46 44 33 33 0d
# ADR: n=Batterienummer (2-x), m=Group Nr. (0-8), ADR = 0x0n + (0x10 * m) -> f. Batterie 1 = 0x02 + (0x10 * 0) = 0x02
# CID1: Kommando spezifisch, hier 46H
# CID2: Kommando spezifisch, hier 51H
# LENGTH: LENID + LCHKSUM -> Pylon LFP V2.8 Doku
# INFO: muß hier mit ADR übereinstimmen
# CHKSUM: 32+30+30+32+34+36+35+31+45+30+30+32+30+32 = 02CDH -> modulo 65536 = 02CDH -> bitweise invert = 1111 1101 0011 0010 -> +1 = 1111 1101 0011 0011 -> FD33H
# 
# SOI  VER    ADR   CID1  CID2      LENGTH    INFO     CHKSUM
#  ~    20    02      46    51     E0    02    02      FD   33
# 7E  32 30  30 32  34 36 35 31  45 30 30 32  30 32  46 44 32 44
#
my %hrmfi = (                                                        # Codierung Abruf manufacturerInfo, mlen = Mindestlänge Antwortstring
  1 => { cmd => "~20024651E00202FD33\x{0d}", mlen => 82 },
  2 => { cmd => "~20034651E00203FD31\x{0d}", mlen => 82 },
  3 => { cmd => "~20044651E00204FD2F\x{0d}", mlen => 82 },
  4 => { cmd => "~20054651E00205FD2D\x{0d}", mlen => 82 },
  5 => { cmd => "~20064651E00206FD2B\x{0d}", mlen => 82 },
  6 => { cmd => "~20074651E00207FD29\x{0d}", mlen => 82 },
);

# request command für '1': ~20024651E00202FD33 + CR
# command (HEX):           
# ADR: n=Batterienummer (2-x), m=Group Nr. (0-8), ADR = 0x0n + (0x10 * m) -> f. Batterie 1 = 0x02 + (0x10 * 0) = 0x02
# CID1: Kommando spezifisch, hier 46H
# CID2: Kommando spezifisch, hier 4FH
# LENGTH: LENID + LCHKSUM -> Pylon LFP V2.8 Doku
# INFO: muß hier mit ADR übereinstimmen
# CHKSUM: 30+30+30+33+34+36+34+46+45+30+30+32+30+33 = 02E1H -> modulo 65536 = 02E1H -> bitweise invert = 1111 1101 0001 1110 -> +1 = 1111 1101 0001 1111 -> FD1FH
# 
# SOI  VER    ADR   CID1   CID2      LENGTH    INFO     CHKSUM
#  ~    00    02      46    4F      E0    02    02      FD   21
# 7E  30 30  30 32  34 36  34 46  45 30 30 32  30 32  46 44 31 46
#
my %hrprt = (                                                        # Codierung Abruf protocolVersion, mlen = Mindestlänge Antwortstring
  1 => { cmd => "~0002464FE00202FD21\x{0d}", mlen => 18 },
  2 => { cmd => "~0003464FE00203FD1F\x{0d}", mlen => 18 },
  3 => { cmd => "~0004464FE00204FD1D\x{0d}", mlen => 18 },
  4 => { cmd => "~0005464FE00205FD1B\x{0d}", mlen => 18 },
  5 => { cmd => "~0006464FE00206FD19\x{0d}", mlen => 18 },
  6 => { cmd => "~0007464FE00207FD17\x{0d}", mlen => 18 },
);


my %hrswv = (                                                        # Codierung Abruf softwareVersion
  1 => { cmd => "~20024696E00202FD2A\x{0d}", mlen => 30 },
  2 => { cmd => "~20034696E00203FD28\x{0d}", mlen => 30 },
  3 => { cmd => "~20044696E00204FD26\x{0d}", mlen => 30 },
  4 => { cmd => "~20054696E00205FD24\x{0d}", mlen => 30 },
  5 => { cmd => "~20064696E00206FD22\x{0d}", mlen => 30 },
  6 => { cmd => "~20074696E00207FD20\x{0d}", mlen => 30 },
);

my %hralm = (                                                        # Codierung Abruf alarmInfo
  1 => { cmd => "~20024644E00202FD31\x{0d}", mlen => 82 },
  2 => { cmd => "~20034644E00203FD2F\x{0d}", mlen => 82 },
  3 => { cmd => "~20044644E00204FD2D\x{0d}", mlen => 82 },
  4 => { cmd => "~20054644E00205FD2B\x{0d}", mlen => 82 },
  5 => { cmd => "~20064644E00206FD29\x{0d}", mlen => 82 },
  6 => { cmd => "~20074644E00207FD27\x{0d}", mlen => 82 },
);

my %hrspm = (                                                        # Codierung Abruf Systemparameter
  1 => { cmd => "~20024647E00202FD2E\x{0d}", mlen => 68 },
  2 => { cmd => "~20034647E00203FD2C\x{0d}", mlen => 68 },
  3 => { cmd => "~20044647E00204FD2A\x{0d}", mlen => 68 },
  4 => { cmd => "~20054647E00205FD28\x{0d}", mlen => 68 },
  5 => { cmd => "~20064647E00206FD26\x{0d}", mlen => 68 },
  6 => { cmd => "~20074647E00207FD24\x{0d}", mlen => 68 },
);

my %hrcmi = (                                                        # Codierung Abruf chargeManagmentInfo, mlen = Mindestlänge Antwortstring
  1 => { cmd => "~20024692E00202FD2E\x{0d}", mlen => 38 },
  2 => { cmd => "~20034692E00203FD2C\x{0d}", mlen => 38 },
  3 => { cmd => "~20044692E00204FD2A\x{0d}", mlen => 38 },
  4 => { cmd => "~20054692E00205FD28\x{0d}", mlen => 38 },
  5 => { cmd => "~20064692E00206FD26\x{0d}", mlen => 38 },
  6 => { cmd => "~20074692E00207FD24\x{0d}", mlen => 38 },
);

my %hrcmn = (                                                        # Codierung Abruf analogValue, mlen = Mindestlänge Antwortstring
  1 => { cmd => "~20024642E00202FD33\x{0d}", mlen => 128 },
  2 => { cmd => "~20034642E00203FD31\x{0d}", mlen => 128 },
  3 => { cmd => "~20044642E00204FD2F\x{0d}", mlen => 128 },
  4 => { cmd => "~20054642E00205FD2D\x{0d}", mlen => 128 },
  5 => { cmd => "~20064642E00206FD2B\x{0d}", mlen => 128 },
  6 => { cmd => "~20074642E00207FD29\x{0d}", mlen => 128 },
);


###############################################################
#                  PylonLowVoltage Initialize
###############################################################
sub Initialize {
  my $hash = shift;

  $hash->{DefFn}      = \&Define;
  $hash->{UndefFn}    = \&Undef;
  $hash->{GetFn}      = \&Get;
  $hash->{AttrFn}     = \&Attr;
  $hash->{ShutdownFn} = \&Shutdown;
  $hash->{AttrList}   = "disable:1,0 ".
                        "interval ".
                        "timeout ".
                        $readingFnAttributes;
                        
  eval { FHEM::Meta::InitMod( __FILE__, $hash ) };     ## no critic 'eval'
  
return;
}

###############################################################
#                  PylonLowVoltage Define
###############################################################
sub Define {
  my ($hash, $def) = @_;
  my @args         = split m{\s+}x, $def;

  if (int(@args) < 2) {
      return "Define: too few arguments. Usage:\n" .
              "define <name> PylonLowVoltage <host>:<port> [<bataddress>]";
  }
  
  my $name = $hash->{NAME};
  
  if ($iostAbsent) {
      my $err = "Perl module >$iostAbsent< is missing. You have to install this perl module.";
      Log3 ($name, 1, "$name - ERROR - $err");
      return "Error: $err";
  }

  $hash->{HELPER}{MODMETAABSENT} = 1 if($modMetaAbsent);                           # Modul Meta.pm nicht vorhanden
  ($hash->{HOST}, $hash->{PORT}) = split ":", $args[2];
  $hash->{BATADDRESS}            = $args[3] // 1;
  
  if ($hash->{BATADDRESS} !~ /[123456]/xs) {
      return "Define: bataddress must be a value between 1 and 6";
  }
    
  my $params = {
      hash        => $hash,
      notes       => \%vNotesIntern,
      useAPI      => 0,
      useSMUtils  => 1,
      useErrCodes => 0,
      useCTZ      => 0,
  };
  use version 0.77; our $VERSION = moduleVersion ($params);                        # Versionsinformationen setzen

  _closeSocket ($hash);
  Update       ($hash);

return;
}

###############################################################
#                  PylonLowVoltage Get
###############################################################
sub Get {
  my ($hash, @a) = @_;
  return qq{"get X" needs at least an argument} if(@a < 2);
  my $name = shift @a;
  my $opt  = shift @a;
  my $arg  = join " ", map { my $p = $_; $p =~ s/\s//xg; $p; } @a;     ## no critic 'Map blocks'

  my $getlist = "Unknown argument $opt, choose one of ".
                "data:noArg "
                ;

  return if(IsDisabled($name));

  if ($opt eq 'data') {
      Update ($hash);
      return;
  }

return $getlist;
}

###############################################################
#                  PylonLowVoltage Update
###############################################################
sub Attr {
  my $cmd   = shift;
  my $name  = shift;
  my $aName = shift;
  my $aVal  = shift;
  my $hash  = $defs{$name};

  my ($do,$val);

  # $cmd can be "del" or "set"
  # $name is device name
  # aName and aVal are Attribute name and value

  if ($aName eq 'disable') {
      if($cmd eq 'set') {
          $do = $aVal ? 1 : 0;
      }

      $do  = 0 if($cmd eq 'del');
      $val = ($do == 1 ? 'disabled' : 'initialized');

      readingsSingleUpdate ($hash, 'state', $val, 1);

      if ($do == 0) {
          InternalTimer(gettimeofday() + 2.0, "FHEM::PylonLowVoltage::Update", $hash, 0);
      }
      else {
          deleteReadingspec ($hash);
          readingsDelete    ($hash, 'nextCycletime');
          _closeSocket      ($hash);
      }
  }

  if ($aName eq "interval") {
      if (!looks_like_number($aVal)) {
          return qq{The value for $aName is invalid, it must be numeric!};
      }

      InternalTimer(gettimeofday()+1.0, "FHEM::PylonLowVoltage::Update", $hash, 0);
  }
  
  if ($aName eq "timeout") {
      if (!looks_like_number($aVal)) {
          return qq{The value for $aName is invalid, it must be numeric!};
      }
  }

return;
}

###############################################################
#                  PylonLowVoltage Update
###############################################################
sub Update {
    my $hash = shift;
    my $name = $hash->{NAME};

    RemoveInternalTimer ($hash);

    if(!$init_done) {
        InternalTimer(gettimeofday() + 2, "FHEM::PylonLowVoltage::Update", $hash, 0);
        return;
    }

    return if(IsDisabled ($name));

    my $interval  = AttrVal ($name, 'interval',   $definterval);                               # 0 -> manuell gesteuert
    my $timeout   = AttrVal ($name, 'timeout',          $defto);             
    my %readings  = ();
    
    my ($socket, $success);

    if(!$interval) {
        $hash->{OPMODE}          = 'Manual';
        $readings{nextCycletime} = 'Manual';
    }
    else {
        my $new = gettimeofday() + $interval;
        InternalTimer ($new, "FHEM::PylonLowVoltage::Update", $hash, 0);                       # Wiederholungsintervall
        
        $hash->{OPMODE}          = 'Automatic';
        $readings{nextCycletime} = FmtTime($new);
    }

    Log3 ($name, 4, "$name - start request cycle to battery number >$hash->{BATADDRESS}< at host:port $hash->{HOST}:$hash->{PORT}");

    eval {                                                                                     ## no critic 'eval'
        local $SIG{ALRM} = sub { croak 'gatewaytimeout' };
        ualarm ($timeout * 1000000);                                                           # ualarm in Mikrosekunden

        $socket = _openSocket ($hash, $timeout, \%readings);
        return if(!$socket);
        
        if (ReadingsAge ($name, "serialNumber", 601) >= 60) {                    # relativ statische Werte abrufen
            return if(_callSerialNumber     ($hash, $socket, \%readings));       # Abruf serialNumber
            return if(_callManufacturerInfo ($hash, $socket, \%readings));       # Abruf manufacturerInfo            
            return if(_callProtocolVersion  ($hash, $socket, \%readings));       # Abruf protocolVersion
            return if(_callSoftwareVersion  ($hash, $socket, \%readings));       # Abruf softwareVersion
            return if(_callSystemParameters ($hash, $socket, \%readings));       # Abruf systemParameters
        }   
               
        return if(_callAlarmInfo            ($hash, $socket, \%readings));       # Abruf alarmInfo
        return if(_callChargeManagmentInfo  ($hash, $socket, \%readings));       # Abruf chargeManagmentInfo      
        return if(_callAnalogValue          ($hash, $socket, \%readings));       # Abruf analogValue
        
        $success = 1;
    };  # eval
    
    if ($@) {
        my $errtxt;
        if ($@ =~ /gatewaytimeout/xs) {
            $errtxt = 'Timeout in communication to RS485 gateway';                         
        }
        else {
            $errtxt = $@; 
        }        
        
        doOnError ({ hash     => $hash, 
                     readings => \%readings, 
                     sock     => $socket,
                     state    => $errtxt,
                     verbose  => 3
                   }
                  );          
        return;
    }

    ualarm(0);
    _closeSocket ($hash);
    
    if ($success) {
        Log3 ($name, 4, "$name - got data from battery number >$hash->{BATADDRESS}< successfully");
        
        additionalReadings (\%readings);                                                 # zusätzliche eigene Readings erstellen
        $readings{state} = 'connected';
    }
    
    createReadings ($hash, \%readings);                                                  # Readings erstellen

return;
}

###############################################################
#       Socket erstellen
###############################################################
sub _openSocket {               
  my $hash     = shift; 
  my $timeout  = shift;    
  my $readings = shift;                # Referenz auf das Hash der zu erstellenden Readings
  
  my $socket   = $hash->{SOCKET};
  
  if ($socket && !$socket->connected()) {
      doOnError ({ hash     => $hash, 
                   readings => $readings,
                   sock     => $socket,                         
                   state    => 'disconnected'
                 }
                );
      
      _closeSocket ($hash);
      undef $socket;
  }
  
  if (!$socket) {
      $socket = IO::Socket::INET->new( Proto    => 'tcp', 
                                       PeerAddr => $hash->{HOST}, 
                                       PeerPort => $hash->{PORT}, 
                                       Timeout  => $timeout
                                     ) 
                or do { doOnError ({ hash     => $hash, 
                                     readings => $readings, 
                                     state    => 'no connection is established to RS485 gateway',
                                     verbose  => 3
                                   }
                                  );           
                        return;                 
                };                                     
  }

  IO::Socket::Timeout->enable_timeouts_on ($socket);                       # nur notwendig für read or write timeout
  my $rwto = $timeout - 0.05;
  $rwto    = $rwto <= 0 ? 0.005 : $rwto; 
    
  $socket->read_timeout  ($rwto);                                          # Read/Writetimeout immer kleiner als Sockettimeout
  $socket->write_timeout ($rwto);
  $socket->autoflush();
  
  $hash->{SOCKET} = $socket;
        
return $socket;
}

###############################################################
#       Socket schließen und löschen
###############################################################
sub _closeSocket {               
  my $hash = shift; 
  
  my $name   = $hash->{NAME};
  my $socket = $hash->{SOCKET};
  
  if ($socket) {
      close ($socket);
      delete $hash->{SOCKET};
      
      Log3 ($name, 4, "$name - Socket/Connection to the RS485 gateway was closed as scheduled");
  }
    
return;
}

###############################################################
#       Abruf serialNumber
###############################################################
sub _callSerialNumber {
  my $hash     = shift;
  my $socket   = shift;    
  my $readings = shift;                # Referenz auf das Hash der zu erstellenden Readings

  my $res = Request ({ hash   => $hash, 
                       socket => $socket, 
                       cmd    => $hrsnb{$hash->{BATADDRESS}}{cmd}, 
                       cmdtxt => 'serialNumber'
                     }
                    );

  my $rtnerr = responseCheck ($res, $hrsnb{$hash->{BATADDRESS}}{mlen});
  
  if ($rtnerr) {
      doOnError ({ hash     => $hash, 
                   readings => $readings,
                   sock     => $socket,                             
                   state    => $rtnerr
                 }
                );                
      return $rtnerr;
  }
  
  __resultLog ($hash, $res);

  my $sernum                = substr ($res, 15, 32);
  $readings->{serialNumber} = pack   ("H*", $sernum);
    
return;
}

###############################################################
#       Abruf manufacturerInfo
###############################################################
sub _callManufacturerInfo {
  my $hash     = shift;
  my $socket   = shift;    
  my $readings = shift;                # Referenz auf das Hash der zu erstellenden Readings

  my $res = Request ({ hash   => $hash, 
                       socket => $socket, 
                       cmd    => $hrmfi{$hash->{BATADDRESS}}{cmd}, 
                       cmdtxt => 'manufacturerInfo'
                     }
                    );
    
  my $rtnerr = responseCheck ($res, $hrmfi{$hash->{BATADDRESS}}{mlen});
  
  if ($rtnerr) {
      doOnError ({ hash     => $hash, 
                   readings => $readings,
                   sock     => $socket,                             
                   state    => $rtnerr
                 }
                );                
      return $rtnerr;
  }
  
  __resultLog ($hash, $res);

  my $BatteryHex               = substr ($res, 13, 20);                       
  $readings->{batteryType}     = pack   ("H*", $BatteryHex);
  $readings->{softwareVersion} = 'V'.hex (substr ($res, 33, 2)).'.'.hex (substr ($res, 35, 2));      # 
  my $ManufacturerHex          = substr ($res, 37, 40);
  $readings->{Manufacturer}    = pack   ("H*", $ManufacturerHex);
    
return;
}

###############################################################
#       Abruf protocolVersion
###############################################################
sub _callProtocolVersion {
  my $hash     = shift;
  my $socket   = shift;    
  my $readings = shift;                # Referenz auf das Hash der zu erstellenden Readings

  my $res = Request ({ hash   => $hash, 
                       socket => $socket, 
                       cmd    => $hrprt{$hash->{BATADDRESS}}{cmd}, 
                       cmdtxt => 'protocolVersion'
                     }
                    );
    
  my $rtnerr = responseCheck ($res, $hrprt{$hash->{BATADDRESS}}{mlen});
  
  if ($rtnerr) {
      doOnError ({ hash     => $hash, 
                   readings => $readings,
                   sock     => $socket,                             
                   state    => $rtnerr
                 }
                );                
      return $rtnerr;
  }
  
  __resultLog ($hash, $res);

  $readings->{protocolVersion} = 'V'.hex (substr ($res, 1, 1)).'.'.hex (substr ($res, 2, 1));
    
return;
}

###############################################################
#       Abruf softwareVersion
###############################################################
sub _callSoftwareVersion {
  my $hash     = shift;
  my $socket   = shift;    
  my $readings = shift;                # Referenz auf das Hash der zu erstellenden Readings

  my $res = Request ({ hash   => $hash, 
                       socket => $socket, 
                       cmd    => $hrswv{$hash->{BATADDRESS}}{cmd}, 
                       cmdtxt => 'softwareVersion'
                     }
                    );
    
  my $rtnerr = responseCheck ($res, $hrswv{$hash->{BATADDRESS}}{mlen});
  
  if ($rtnerr) {
      doOnError ({ hash     => $hash, 
                   readings => $readings,
                   sock     => $socket,                             
                   state    => $rtnerr
                 }
                );                
      return $rtnerr;
  }
  
  __resultLog ($hash, $res);

  $readings->{moduleSoftwareVersion_manufacture} = 'V'.hex (substr ($res, 15, 2)).'.'.hex (substr ($res, 17, 2)); 
  $readings->{moduleSoftwareVersion_mainline}    = 'V'.hex (substr ($res, 19, 2)).'.'.hex (substr ($res, 21, 2)).'.'.hex (substr ($res, 23, 2));
  
return;
}

###############################################################
#       Abruf systemParameters
###############################################################
sub _callSystemParameters {
  my $hash     = shift;
  my $socket   = shift;    
  my $readings = shift;                # Referenz auf das Hash der zu erstellenden Readings

  my $res = Request ({ hash   => $hash, 
                       socket => $socket, 
                       cmd    => $hrspm{$hash->{BATADDRESS}}{cmd}, 
                       cmdtxt => 'systemParameters'
                     }
                    );
    
  my $rtnerr = responseCheck ($res, $hrspm{$hash->{BATADDRESS}}{mlen});
  
  if ($rtnerr) {
      doOnError ({ hash     => $hash, 
                   readings => $readings,
                   sock     => $socket,                             
                   state    => $rtnerr
                 }
                );                
      return $rtnerr;
  }
  
  __resultLog ($hash, $res);

  $readings->{paramCellHighVoltLimit}      = sprintf "%.3f", (hex substr  ($res, 15, 4)) / 1000;
  $readings->{paramCellLowVoltLimit}       = sprintf "%.3f", (hex substr  ($res, 19, 4)) / 1000;                   # Alarm Limit
  $readings->{paramCellUnderVoltLimit}     = sprintf "%.3f", (hex substr  ($res, 23, 4)) / 1000;                   # Schutz Limit
  $readings->{paramChargeHighTempLimit}    = sprintf "%.1f", ((hex substr ($res, 27, 4)) - 2731) / 10; 
  $readings->{paramChargeLowTempLimit}     = sprintf "%.1f", ((hex substr ($res, 31, 4)) - 2731) / 10; 
  $readings->{paramChargeCurrentLimit}     = sprintf "%.3f", (hex substr  ($res, 35, 4)) * 100 / 1000; 
  $readings->{paramModuleHighVoltLimit}    = sprintf "%.3f", (hex substr  ($res, 39, 4)) / 1000;
  $readings->{paramModuleLowVoltLimit}     = sprintf "%.3f", (hex substr  ($res, 43, 4)) / 1000;                   # Alarm Limit
  $readings->{paramModuleUnderVoltLimit}   = sprintf "%.3f", (hex substr  ($res, 47, 4)) / 1000;                   # Schutz Limit
  $readings->{paramDischargeHighTempLimit} = sprintf "%.1f", ((hex substr ($res, 51, 4)) - 2731) / 10;
  $readings->{paramDischargeLowTempLimit}  = sprintf "%.1f", ((hex substr ($res, 55, 4)) - 2731) / 10;
  $readings->{paramDischargeCurrentLimit}  = sprintf "%.3f", (65535 - (hex substr  ($res, 59, 4))) * 100 / 1000;   # mit Symbol (-)
  
return;
}

###############################################################
#       Abruf alarmInfo
###############################################################
sub _callAlarmInfo {
  my $hash     = shift;
  my $socket   = shift;    
  my $readings = shift;                # Referenz auf das Hash der zu erstellenden Readings

  my $res = Request ({ hash   => $hash, 
                       socket => $socket, 
                       cmd    => $hralm{$hash->{BATADDRESS}}{cmd}, 
                       cmdtxt => 'alarmInfo'
                     }
                    );
    
  my $rtnerr = responseCheck ($res, $hralm{$hash->{BATADDRESS}}{mlen});
  
  if ($rtnerr) {
      doOnError ({ hash     => $hash, 
                   readings => $readings,
                   sock     => $socket,                             
                   state    => $rtnerr
                 }
                );                
      return $rtnerr;
  }
  
  __resultLog ($hash, $res);

  $readings->{packCellcount} = hex (substr($res, 17, 2));

  if (substr($res, 19, 30) eq "000000000000000000000000000000" && 
      substr($res, 51, 10) eq "0000000000"                     && 
      substr($res, 67, 2)  eq "00"                             && 
      substr($res, 73, 4)  eq "0000") {
      $readings->{packAlarmInfo} = "ok";
  }
  else {
      $readings->{packAlarmInfo} = "failure";
  }
        
return;
}

###############################################################
#       Abruf chargeManagmentInfo
###############################################################
sub _callChargeManagmentInfo {
  my $hash     = shift;
  my $socket   = shift;    
  my $readings = shift;                # Referenz auf das Hash der zu erstellenden Readings

  my $res = Request ({ hash   => $hash, 
                       socket => $socket, 
                       cmd    => $hrcmi{$hash->{BATADDRESS}}{cmd}, 
                       cmdtxt => 'chargeManagmentInfo'
                     }
                    );
    
  my $rtnerr = responseCheck ($res, $hrcmi{$hash->{BATADDRESS}}{mlen});
  
  if ($rtnerr) {
      doOnError ({ hash     => $hash, 
                   readings => $readings,
                   sock     => $socket,                             
                   state    => $rtnerr
                 }
                );                
      return $rtnerr;
  }
  
  __resultLog ($hash, $res);

  $readings->{chargeVoltageLimit}     = sprintf "%.3f", hex (substr ($res, 15, 4)) / 1000;        # Genauigkeit 3
  $readings->{dischargeVoltageLimit}  = sprintf "%.3f", hex (substr ($res, 19, 4)) / 1000;        # Genauigkeit 3
  $readings->{chargeCurrentLimit}     = sprintf "%.1f", hex (substr ($res, 23, 4)) / 10;          # Genauigkeit 1
  $readings->{dischargeCurrentLimit}  = sprintf "%.1f", (65536 - hex substr ($res, 27, 4)) / 10;  # Genauigkeit 1, Fixed point, unsigned integer

  my $cdstat                          = sprintf "%08b", hex substr ($res, 31, 2);                 # Rohstatus
  $readings->{chargeEnable}           = substr ($cdstat, 0, 1) == 1 ? 'yes' : 'no';               # Bit 7
  $readings->{dischargeEnable}        = substr ($cdstat, 1, 1) == 1 ? 'yes' : 'no';               # Bit 6
  $readings->{chargeImmediatelySOC05} = substr ($cdstat, 2, 1) == 1 ? 'yes' : 'no';               # Bit 5 - SOC 5~9%  -> für Wechselrichter, die aktives Batteriemanagement bei gegebener DC-Spannungsfunktion haben oder Wechselrichter, der von sich aus einen niedrigen SOC/Spannungsgrenzwert hat
  $readings->{chargeImmediatelySOC09} = substr ($cdstat, 3, 1) == 1 ? 'yes' : 'no';               # Bit 4 - SOC 9~13% -> für Wechselrichter hat keine aktive Batterieabschaltung haben
  $readings->{chargeFullRequest}      = substr ($cdstat, 4, 1) == 1 ? 'yes' : 'no';               # Bit 3 - wenn SOC in 30 Tagen nie höher als 97% -> Flag = 1, wenn SOC-Wert ≥ 97% -> Flag = 0
        
return;
}

#################################################################################
#       Abruf analogValue
# Answer from US2000 = 128 Bytes, from US3000 = 140 Bytes
# Remain capacity US2000 hex(substr($res,109,4), US3000 hex(substr($res,123,6)
# Module capacity US2000 hex(substr($res,115,4), US3000 hex(substr($res,129,6)
#################################################################################
sub _callAnalogValue {
  my $hash     = shift;
  my $socket   = shift;    
  my $readings = shift;                # Referenz auf das Hash der zu erstellenden Readings

  my $res = Request ({ hash   => $hash, 
                       socket => $socket, 
                       cmd    => $hrcmn{$hash->{BATADDRESS}}{cmd}, 
                       cmdtxt => 'analogValue'
                     }
                    );
    
  my $rtnerr = responseCheck ($res, $hrcmn{$hash->{BATADDRESS}}{mlen});
  
  if ($rtnerr) {
      doOnError ({ hash     => $hash, 
                   readings => $readings,
                   sock     => $socket,                             
                   state    => $rtnerr
                 }
                );                
      return $rtnerr;
  }
  
  __resultLog ($hash, $res);

  $readings->{packCellcount}        = hex (substr($res, 17,  2));
  $readings->{cellVoltage_01}       = sprintf "%.3f", hex(substr($res,19,4)) / 1000;
  $readings->{cellVoltage_02}       = sprintf "%.3f", hex(substr($res,23,4)) / 1000;
  $readings->{cellVoltage_03}       = sprintf "%.3f", hex(substr($res,27,4)) / 1000;
  $readings->{cellVoltage_04}       = sprintf "%.3f", hex(substr($res,31,4)) / 1000;
  $readings->{cellVoltage_05}       = sprintf "%.3f", hex(substr($res,35,4)) / 1000;
  $readings->{cellVoltage_06}       = sprintf "%.3f", hex(substr($res,39,4)) / 1000;
  $readings->{cellVoltage_07}       = sprintf "%.3f", hex(substr($res,43,4)) / 1000;
  $readings->{cellVoltage_08}       = sprintf "%.3f", hex(substr($res,47,4)) / 1000;
  $readings->{cellVoltage_09}       = sprintf "%.3f", hex(substr($res,51,4)) / 1000;
  $readings->{cellVoltage_10}       = sprintf "%.3f", hex(substr($res,55,4)) / 1000;
  $readings->{cellVoltage_11}       = sprintf "%.3f", hex(substr($res,59,4)) / 1000;
  $readings->{cellVoltage_12}       = sprintf "%.3f", hex(substr($res,63,4)) / 1000;
  $readings->{cellVoltage_13}       = sprintf "%.3f", hex(substr($res,67,4)) / 1000;
  $readings->{cellVoltage_14}       = sprintf "%.3f", hex(substr($res,71,4)) / 1000;
  $readings->{cellVoltage_15}       = sprintf "%.3f", hex(substr($res,75,4)) / 1000; 
  # $readings->{numberOfTempPos}     =                 hex(substr($res,79,2));              # Anzahl der jetzt folgenden Teperaturpositionen -> 5
  $readings->{bmsTemperature}       = (hex (substr($res, 81,  4)) - 2731) / 10;             # 1
  $readings->{cellTemperature_0104} = (hex (substr($res, 85,  4)) - 2731) / 10;             # 2
  $readings->{cellTemperature_0508} = (hex (substr($res, 89,  4)) - 2731) / 10;             # 3
  $readings->{cellTemperature_0912} = (hex (substr($res, 93,  4)) - 2731) / 10;             # 4
  $readings->{cellTemperature_1315} = (hex (substr($res, 97,  4)) - 2731) / 10;             # 5
  my $current                       =  hex (substr($res, 101, 4));     
  $readings->{packVolt}             = sprintf "%.3f", hex (substr($res, 105, 4)) / 1000;
    
  if ($current & 0x8000) {
      $current = $current - 0x10000;
  }

  $readings->{packCurrent} = sprintf "%.3f", $current / 10;
  my $udi                  = hex substr($res, 113, 2);                                      # user defined item=Entscheidungskriterium -> 2: Batterien <= 65Ah, 4: Batterien > 65Ah
  $readings->{packCycles}  = hex substr($res, 119, 4);

  if ($udi == 2) {
      $readings->{packCapacityRemain} = sprintf "%.3f", hex (substr($res, 109, 4)) / 1000;
      $readings->{packCapacity}       = sprintf "%.3f", hex (substr($res, 115, 4)) / 1000;
  }
  elsif ($udi == 4) {
      $readings->{packCapacityRemain} = sprintf "%.3f", hex (substr($res, 123, 6)) / 1000;
      $readings->{packCapacity}       = sprintf "%.3f", hex (substr($res, 129, 6)) / 1000;
  }
  else {
      my $err = 'wrong value retrieve analogValue -> user defined items: '.$udi;
      doOnError ({ hash     => $hash, 
                   readings => $readings,
                   sock     => $socket,                             
                   state    => $err
                 }
                );                
      return $err;
  }
        
return;
}

###############################################################
#        Logausgabe Result
###############################################################
sub __resultLog {           
  my $hash = shift;
  my $res  = shift;

  my $name = $hash->{NAME};

  Log3 ($name, 5, "$name - data returned raw: ".$res);
  Log3 ($name, 5, "$name - data returned:\n"   .Hexdump ($res));              
    
return;
}

###############################################################
#                  PylonLowVoltage Request
###############################################################
sub Request {    
  my $paref = shift;

  my $hash   = $paref->{hash};
  my $socket = $paref->{socket};  
  my $cmd    = $paref->{cmd};
  my $cmdtxt = $paref->{cmdtxt} // 'unspecified data';
    
  my $name = $hash->{NAME};
    
  Log3 ($name, 4, "$name - retrieve battery info: ".$cmdtxt);
  Log3 ($name, 4, "$name - request command (ASCII): ".$cmd);
  Log3 ($name, 5, "$name - request command (HEX): ".unpack "H*", $cmd);  

  printf $socket $cmd;

return Reread ($hash, $socket);
}

###############################################################
#    RS485 Daten lesen/empfagen
###############################################################
sub Reread {
    my $hash   = shift;
    my $socket = shift;

    my $singlechar;
    my $res = q{};

    do {        
        $socket->read ($singlechar, 1);

        if (!$singlechar && (0+$! == ETIMEDOUT || 0+$! == EWOULDBLOCK)) {                # nur notwendig für read timeout
            croak 'Timeout reading data from battery';
        }

        $res = $res . $singlechar if(length $singlechar != 0 && $singlechar =~ /[~A-Z0-9\r]+/xs);

    } while (length $singlechar == 0 || ord($singlechar) != 13);
    
return $res;
}

###############################################################
#                  PylonLowVoltage Undef
###############################################################
sub Shutdown {
  my ($hash, $args) = @_;
  
  RemoveInternalTimer ($hash);
  _closeSocket        ($hash); 

return;
}

###############################################################
#                  PylonLowVoltage Hexdump
###############################################################
sub Hexdump {
  my $res = shift;
  
  my $offset = 0;
  my $result = "";

  for my $chunk (unpack "(a16)*", $res) {
      my $hex  = unpack "H*", $chunk;                                                       # hexadecimal magic
      $chunk   =~ tr/ -~/./c;                                                               # replace unprintables
      $hex     =~ s/(.{1,8})/$1 /gxs;                                                       # insert spaces
      $result .= sprintf "0x%08x (%05u)  %-*s %s\n", $offset, $offset, 36, $hex, $chunk;
      $offset += 16;
  }

return $result;
}

###############################################################
#       Response Status ermitteln
###############################################################
sub responseCheck {               
  my $res  = shift;
  my $mlen = shift // 0;                # Mindestlänge Antwortstring

  my $rtnerr = $hrtnc{99}{desc};
  
  if(!$res || $res !~ /^[~A-Z0-9]+\r$/xs) {
      return $rtnerr;
  }
  
  my $len = length($res);
  
  if ($len < $mlen) {
      $rtnerr = $hrtnc{98}{desc};
      $rtnerr =~ s/<LEN>/$len/xs;
      $rtnerr =~ s/<MLEN>/$mlen/xs;
      return $rtnerr;
  }
  
  my $rtn = q{_};
  $rtn    = substr($res,7,2) if($res && $len >= 10);
    
  if(defined $hrtnc{$rtn}{desc} && substr($res, 0, 1) eq '~') {
      $rtnerr = $hrtnc{$rtn}{desc};
      return if($rtnerr eq 'normal');
  }
    
return $rtnerr;
}

###############################################################
#       Fehlerausstieg
###############################################################
sub doOnError {           
  my $paref = shift;

  my $hash     = $paref->{hash};
  my $readings = $paref->{readings};     # Referenz auf das Hash der zu erstellenden Readings
  my $state    = $paref->{state};
  my $socket   = $paref->{sock};
  my $verbose  = $paref->{verbose} // 4;
  
  ualarm(0);

  my $name           = $hash->{NAME};
  $state             = (split "at ", $state)[0];
  $readings->{state} = $state;
  $verbose           = 3 if($readings->{state} =~ /error/xsi);
  
  Log3 ($name, $verbose, "$name - ".$readings->{state});
  
  _closeSocket      ($hash);
  deleteReadingspec ($hash);
  createReadings    ($hash, $readings);                
    
return;
}

###############################################################
#       eigene zusaätzliche Werte erstellen
###############################################################
sub additionalReadings {               
    my $readings = shift;                # Referenz auf das Hash der zu erstellenden Readings

    my ($vmax, $vmin);
    
    $readings->{averageCellVolt} = sprintf "%.3f", $readings->{packVolt} / $readings->{packCellcount}                  if(defined $readings->{packCellcount});
    $readings->{packSOC}         = sprintf "%.2f", ($readings->{packCapacityRemain} / $readings->{packCapacity} * 100) if(defined $readings->{packCapacity});
    $readings->{packPower}       = sprintf "%.2f", $readings->{packCurrent} * $readings->{packVolt};
    
    for (my $i=1; $i <= $readings->{packCellcount}; $i++) {
        $i    = sprintf "%02d", $i;
        $vmax = $readings->{'cellVoltage_'.$i} if(!$vmax || $vmax < $readings->{'cellVoltage_'.$i});
        $vmin = $readings->{'cellVoltage_'.$i} if(!$vmin || $vmin > $readings->{'cellVoltage_'.$i});
    }
    
    if ($vmax && $vmin) {
        my $maxdf = $vmax - $vmin;
        $readings->{packImbalance} = sprintf "%.3f", 100 * $maxdf / $readings->{averageCellVolt};
    }
    
    $readings->{packState} = $readings->{packCurrent} < 0 ? 'discharging' :
                             $readings->{packCurrent} > 0 ? 'charging'    :
                             'idle';
    
return;
}

###############################################################
#       Readings erstellen
###############################################################
sub createReadings {               
    my $hash     = shift;
    my $readings = shift;                # Referenz auf das Hash der zu erstellenden Readings

    readingsBeginUpdate ($hash);
    
    for my $spec (keys %{$readings}) {
        next if(!defined $readings->{$spec});
        readingsBulkUpdate ($hash, $spec, $readings->{$spec});
    }

    readingsEndUpdate  ($hash, 1);
    
return;
}

################################################################
#    alle Readings eines Devices oder nur Reading-Regex
#    löschen
#    Readings der Blacklist werden nicht gelöscht
################################################################
sub deleteReadingspec {
  my $hash = shift;
  my $spec = shift // ".*";

  my $readingspec = '^'.$spec.'$';

  for my $reading ( grep { /$readingspec/x } keys %{$hash->{READINGS}} ) {
      next if($reading ~~ @blackl);
      readingsDelete ($hash, $reading);
  }

return;
}

1;


=pod
=item device
=item summary Integration of Pylontech LiFePo4 low voltage batteries (incl. BMS) over RS485 via ethernet gateway (ethernet interface)
=item summary_DE Integration von Pylontech Niedervolt Batterien (mit BMS) über RS485 via Ethernet-Gateway (Ethernet Interface)

=begin html

<a id="PylonLowVoltage"></a>
<h3>PylonLowVoltage</h3>
<br>
Module for integration of low voltage batteries with battery management system (BMS) of the manufacturer Pylontech via 
RS485/Ethernet gateway. Communication to the RS485 gateway takes place exclusively via an Ethernet connection.<br>
The module has been successfully used so far with Pylontech batteries of the following types: <br>

<ul>
 <li> US2000 </li>
 <li> US2000plus </li>
 <li> US3000 </li>
 <li> US3000C </li>
</ul>

The following devices have been successfully used as RS485 Ethernet gateways to date: <br>
<ul>
 <li> USR-TCP232-304 from the manufacturer USRiot </li>
 <li> Waveshare RS485 to Ethernet Converter       </li>
</ul>
 
In principle, any other RS485/Ethernet gateway should also be compatible.
<br><br>

<b>Requirements</b>
<br><br>
This module requires the Perl modules:
<ul>
    <li>IO::Socket::INET    (apt-get install libio-socket-multicast-perl)                          </li>
    <li>IO::Socket::Timeout (Installation e.g. via the CPAN shell or the FHEM Installer module)    </li>
</ul>

<a id="PylonLowVoltage-define"></a>
<b>Definition</b>
<ul>
  <code><b>define &lt;name&gt; PylonLowVoltage &lt;hostname/ip&gt;:&lt;port&gt; [&lt;bataddress&gt;]</b></code><br>
  <br>
  <li><b>hostname/ip:</b><br>
     Host name or IP address of the RS485/Ethernet gateway
  </li>

  <li><b>port:</b><br>
     Port number of the port configured in the RS485/Ethernet gateway
  </li>
  
  <li><b>bataddress:</b><br>
     Device address of the Pylontech battery. Up to 6 Pylontech batteries can be connected via a Pylontech-specific
     link connection.<br>
     The first battery in the network (to which the RS485 connection is connected) has the address 1, the next battery
     then has address 2 and so on.<br>
     If no device address is specified, address 1 is used.
  </li>
  <br>
</ul>

<b>Mode of operation</b>
<ul>
Depending on the setting of the "Interval" attribute, the module cyclically reads values provided by the battery 
management system via the RS485 interface. 
</ul>

<a id="PylonLowVoltage-get"></a>
<b>Get</b>
<br>
<ul>
  <li><b>data</b><br>
    The data query of the battery management system is executed. The timer of the cyclic query is reinitialized according 
    to the set value of the "interval" attribute.
    <br>
  </li>
<br>
</ul>

<a id="PylonLowVoltage-attr"></a>
<b>Attributes</b>
<br<br>
<ul>
   <a id="PylonLowVoltage-attr-disable"></a>
   <li><b>disable 0|1</b><br>
     Enables/disables the device definition.
   </li>
   <br>

   <a id="PylonLowVoltage-attr-interval"></a>
   <li><b>interval &lt;seconds&gt;</b><br>
     Interval of the data request from the battery in seconds. If "interval" is explicitly set to the value "0", there is 
     no automatic data request.<br>
     (default: 30)
   </li>
   <br>
   
   <a id="PylonLowVoltage-attr-timeout"></a>
   <li><b>timeout &lt;seconds&gt;</b><br>
     Timeout for establishing the connection to the RS485 gateway. <br>
     (default: 0.5)
   </li>
   <br>
</ul>

<a id="PylonLowVoltage-readings"></a>
<b>Readings</b>
<ul>
<li><b>averageCellVolt</b><br>        Average cell voltage (V)                                                           </li>
<li><b>bmsTemperature</b><br>         Temperature (°C) of the battery management system                                  </li>
<li><b>cellTemperature_0104</b><br>   Temperature (°C) of cell packs 1 to 4                                              </li>
<li><b>cellTemperature_0508</b><br>   Temperature (°C) of cell packs 5 to 8                                              </li>
<li><b>cellTemperature_0912</b><br>   Temperature (°C) of the cell packs 9 to 12                                         </li>
<li><b>cellTemperature_1315</b><br>   Temperature (°C) of the cell packs 13 to 15                                        </li>
<li><b>cellVoltage_XX</b><br>         Cell voltage (V) of the cell pack XX. In the battery module "packCellcount" 
                                      cell packs are connected in series. Each cell pack consists of single cells 
                                      connected in parallel.                                                             </li>
<li><b>chargeCurrentLimit</b><br>     current limit value for the charging current (A)                                   </li>
<li><b>chargeEnable</b><br>           current flag loading allowed                                                       </li>
<li><b>chargeFullRequest</b><br>      current flag charge battery module fully (from the mains if necessary)             </li>
<li><b>chargeImmediatelySOCXX</b><br> current flag charge battery module immediately 
                                      (05: SOC limit 5-9%, 09: SOC limit 9-13%)                                          </li>
<li><b>chargeVoltageLimit</b><br>     current charge voltage limit (V) of the battery module                             </li>
<li><b>dischargeCurrentLimit</b><br>  current limit value for the discharge current (A)                                  </li>
<li><b>dischargeEnable</b><br>        current flag unloading allowed                                                     </li>
<li><b>dischargeVoltageLimit</b><br>  current discharge voltage limit (V) of the battery module                          </li>

<li><b>moduleSoftwareVersion_manufacture</b><br> Firmware version of the battery module                                  </li>

<li><b>packAlarmInfo</b><br>          Alarm status (ok - battery module is OK, failure - there is a fault in the 
                                      battery module)                                                                    </li>                                                                                                             
<li><b>packCapacity</b><br>           nominal capacity (Ah) of the battery module                                        </li>
<li><b>packCapacityRemain</b><br>     current capacity (Ah) of the battery module                                        </li>
<li><b>packCellcount</b><br>          Number of cell packs in the battery module                                         </li>
<li><b>packCurrent</b><br>            current charge current (+) or discharge current (-) of the battery module (A)      </li>
<li><b>packCycles</b><br>             Number of full cycles - The number of cycles is, to some extent, a measure of the 
                                      wear and tear of the battery. A complete charge and discharge is counted as one 
                                      cycle. If the battery is discharged and recharged 50%, it only counts as one 
                                      half cycle. Pylontech specifies a lifetime of several 1000 cycles 
                                      (see data sheet).                                                                  </li>
<li><b>packImbalance</b><br>          current imbalance of voltage between the single cells of the 
                                      battery module (%)                                                                 </li>
<li><b>packPower</b><br>              current drawn (+) or delivered (-) power (W) of the battery module                 </li>
<li><b>packSOC</b><br>                State of charge (%) of the battery module                                          </li>
<li><b>packState</b><br>              current working status of the battery module                                       </li>
<li><b>packVolt</b><br>               current voltage (V) of the battery module                                          </li>                                               

<li><b>paramCellHighVoltLimit</b><br>      System parameter upper voltage limit (V) of a cell                                 </li>
<li><b>paramCellLowVoltLimit</b><br>       System parameter lower voltage limit (V) of a cell (alarm limit)                   </li>
<li><b>paramCellUnderVoltLimit</b><br>     System parameter undervoltage limit (V) of a cell (protection limit)               </li>
<li><b>paramChargeCurrentLimit</b><br>     System parameter charging current limit (A) of the battery module                  </li>
<li><b>paramChargeHighTempLimit</b><br>    System parameter upper temperature limit (°C) up to which the battery charges      </li>
<li><b>paramChargeLowTempLimit</b><br>     System parameter lower temperature limit (°C) up to which the battery charges      </li>
<li><b>paramDischargeCurrentLimit</b><br>  System parameter discharge current limit (A) of the battery module                 </li>
<li><b>paramDischargeHighTempLimit</b><br> System parameter upper temperature limit (°C) up to which the battery discharges   </li>
<li><b>paramDischargeLowTempLimit</b><br>  System parameter lower temperature limit (°C) up to which the battery discharges   </li>
<li><b>paramModuleHighVoltLimit</b><br>    System parameter upper voltage limit (V) of the battery module                     </li>
<li><b>paramModuleLowVoltLimit</b><br>     System parameter lower voltage limit (V) of the battery module (alarm limit)       </li>
<li><b>paramModuleUnderVoltLimit</b><br>   System parameter undervoltage limit (V) of the battery module (protection limit)   </li>
<li><b>protocolVersion</b><br>             PYLON low voltage RS485 protocol version                                           </li>
<li><b>serialNumber</b><br>                Serial number                                                                      </li>
<li><b>softwareVersion</b><br>             ---------                                                                          </li>
</ul>
<br><br>

=end html
=begin html_DE

<a id="PylonLowVoltage"></a>
<h3>PylonLowVoltage</h3>
<br>
Modul zur Einbindung von Niedervolt-Batterien mit Batteriemanagmentsystem (BMS) des Herstellers Pylontech über RS485 via 
RS485/Ethernet-Gateway. Die Kommunikation zum RS485-Gateway erfolgt ausschließlich über eine Ethernet-Verbindung.<br>
Das Modul wurde bisher erfolgreich mit Pylontech Batterien folgender Typen eingesetzt: <br>

<ul>
 <li> US2000 </li>
 <li> US2000plus </li>
 <li> US3000 </li>
 <li> US3000C </li>
</ul>

Als RS485-Ethernet-Gateways wurden bisher folgende Geräte erfolgreich eingesetzt: <br>
<ul>
 <li> USR-TCP232-304 des Herstellers USRiot </li>
 <li> Waveshare RS485 to Ethernet Converter </li>
</ul>
 
Prinzipiell sollte auch jedes andere RS485/Ethernet-Gateway kompatibel sein.
<br><br>

<b>Voraussetzungen</b>
<br><br>
Dieses Modul benötigt die Perl-Module:
<ul>
    <li>IO::Socket::INET    (apt-get install libio-socket-multicast-perl)                          </li>
    <li>IO::Socket::Timeout (Installation z.B. über die CPAN-Shell oder das FHEM Installer Modul)  </li>
</ul>

<a id="PylonLowVoltage-define"></a>
<b>Definition</b>
<ul>
  <code><b>define &lt;name&gt; PylonLowVoltage &lt;hostname/ip&gt;:&lt;port&gt; [&lt;bataddress&gt;]</b></code><br>
  <br>
  <li><b>hostname/ip:</b><br>
     Hostname oder IP-Adresse des RS485/Ethernet-Gateways
  </li>

  <li><b>port:</b><br>
     Port-Nummer des im RS485/Ethernet-Gateways konfigurierten Ports
  </li>
  
  <li><b>bataddress:</b><br>
     Geräteadresse der Pylontech Batterie. Es können bis zu 6 Pylontech Batterien über eine Pylontech-spezifische
     Link-Verbindung verbunden werden.<br>
     Die erste Batterie im Verbund (an der die RS485-Verbindung angeschlossen ist) hat die Adresse 1, die nächste Batterie
     hat dann die Adresse 2 und so weiter.<br>
     Ist keine Geräteadresse angegeben, wird die Adresse 1 verwendet.
  </li>
  <br>
</ul>

<b>Arbeitsweise</b>
<ul>
Das Modul liest entsprechend der Einstellung des Attributes "interval" zyklisch Werte aus, die das 
Batteriemanagementsystem über die RS485-Schnittstelle zur Verfügung stellt. 
</ul>

<a id="PylonLowVoltage-get"></a>
<b>Get</b>
<br>
<ul>
  <li><b>data</b><br>
    Die Datenabfrage des Batteriemanagementsystems wird ausgeführt. Der Zeitgeber der zyklischen Abfrage wird entsprechend
    dem gesetzten Wert des Attributes "interval" neu initialisiert.
    <br>
  </li>
<br>
</ul>

<a id="PylonLowVoltage-attr"></a>
<b>Attribute</b>
<br<br>
<ul>
   <a id="PylonLowVoltage-attr-disable"></a>
   <li><b>disable 0|1</b><br>
     Aktiviert/deaktiviert die Gerätedefinition.
   </li>
   <br>

   <a id="PylonLowVoltage-attr-interval"></a>
   <li><b>interval &lt;Sekunden&gt;</b><br>
     Intervall der Datenabfrage von der Batterie in Sekunden. Ist "interval" explizit auf den Wert "0" gesetzt, erfolgt
     keine automatische Datenabfrage.<br>
     (default: 30)
   </li>
   <br>
   
   <a id="PylonLowVoltage-attr-timeout"></a>
   <li><b>timeout &lt;Sekunden&gt;</b><br>
     Timeout für den Verbindungsaufbau zum RS485 Gateway. <br>
     (default: 0.5)
   </li>
   <br>
</ul>

<a id="PylonLowVoltage-readings"></a>
<b>Readings</b>
<ul>
<li><b>averageCellVolt</b><br>        mittlere Zellenspannung (V)                                                        </li>
<li><b>bmsTemperature</b><br>         Temperatur (°C) des Batteriemanagementsystems                                      </li>
<li><b>cellTemperature_0104</b><br>   Temperatur (°C) der Zellenpacks 1 bis 4                                            </li>
<li><b>cellTemperature_0508</b><br>   Temperatur (°C) der Zellenpacks 5 bis 8                                            </li>
<li><b>cellTemperature_0912</b><br>   Temperatur (°C) der Zellenpacks 9 bis 12                                           </li>
<li><b>cellTemperature_1315</b><br>   Temperatur (°C) der Zellenpacks 13 bis 15                                          </li>
<li><b>cellVoltage_XX</b><br>         Zellenspannung (V) des Zellenpacks XX. In dem Batteriemodul sind "packCellcount" 
                                      Zellenpacks in Serie geschaltet verbaut. Jedes Zellenpack besteht aus parallel 
                                      geschalten Einzelzellen.                                                           </li>
<li><b>chargeCurrentLimit</b><br>     aktueller Grenzwert für den Ladestrom (A)                                          </li>
<li><b>chargeEnable</b><br>           aktuelles Flag Laden erlaubt                                                       </li>
<li><b>chargeFullRequest</b><br>      aktuelles Flag Batteriemodul voll laden (notfalls aus dem Netz)                    </li>
<li><b>chargeImmediatelySOCXX</b><br> aktuelles Flag Batteriemodul sofort laden 
                                      (05: SOC Grenze 5-9%, 09: SOC Grenze 9-13%)                                        </li>
<li><b>chargeVoltageLimit</b><br>     aktuelle Ladespannungsgrenze (V) des Batteriemoduls                                </li>
<li><b>dischargeCurrentLimit</b><br>  aktueller Grenzwert für den Entladestrom (A)                                       </li>
<li><b>dischargeEnable</b><br>        aktuelles Flag Entladen erlaubt                                                    </li>
<li><b>dischargeVoltageLimit</b><br>  aktuelle Entladespannungsgrenze (V) des Batteriemoduls                             </li>

<li><b>moduleSoftwareVersion_manufacture</b><br> Firmware Version des Batteriemoduls                                     </li>

<li><b>packAlarmInfo</b><br>          Alarmstatus (ok - Batterienmodul ist in Ordnung, failure - im Batteriemodul liegt 
                                      eine Störung vor)                                                                  </li>                                                                                                             
<li><b>packCapacity</b><br>           nominale Kapazität (Ah) des Batteriemoduls                                         </li>
<li><b>packCapacityRemain</b><br>     aktuelle Kapazität (Ah) des Batteriemoduls                                         </li>
<li><b>packCellcount</b><br>          Anzahl der Zellenpacks im Batteriemodul                                            </li>
<li><b>packCurrent</b><br>            aktueller Ladestrom (+) bzw. Entladstrom (-) des Batteriemoduls (A)                </li>
<li><b>packCycles</b><br>             Anzahl der Vollzyklen - Die Anzahl der Zyklen ist in gewisserweise ein Maß für den 
                                      Verschleiß der Batterie. Eine komplettes Laden und Entladen wird als ein Zyklus 
                                      gewertet. Wird die Batterie 50% entladen und wieder aufgeladen, zählt das nur als ein 
                                      halber Zyklus. Pylontech gibt eine Lebensdauer von mehreren 1000 Zyklen an 
                                      (siehe Datenblatt).                                                                </li>
<li><b>packImbalance</b><br>          aktuelles Ungleichgewicht der Spannung zwischen den Einzelzellen des 
                                      Batteriemoduls (%)                                                                 </li>
<li><b>packPower</b><br>              aktuell bezogene (+) bzw. gelieferte (-) Leistung (W) des Batteriemoduls           </li>
<li><b>packSOC</b><br>                Ladezustand (%) des Batteriemoduls                                                 </li>
<li><b>packState</b><br>              aktueller Arbeitsstatus des Batteriemoduls                                         </li>
<li><b>packVolt</b><br>               aktuelle Spannung (V) des Batteriemoduls                                           </li>                                               

<li><b>paramCellHighVoltLimit</b><br>      Systemparameter obere Spannungsgrenze (V) einer Zelle                         </li>
<li><b>paramCellLowVoltLimit</b><br>       Systemparameter untere Spannungsgrenze (V) einer Zelle (Alarmgrenze)          </li>
<li><b>paramCellUnderVoltLimit</b><br>     Systemparameter Unterspannungsgrenze (V) einer Zelle (Schutzgrenze)           </li>
<li><b>paramChargeCurrentLimit</b><br>     Systemparameter Ladestromgrenze (A) des Batteriemoduls                        </li>
<li><b>paramChargeHighTempLimit</b><br>    Systemparameter obere Temperaturgrenze (°C) bis zu der die Batterie lädt      </li>
<li><b>paramChargeLowTempLimit</b><br>     Systemparameter untere Temperaturgrenze (°C) bis zu der die Batterie lädt     </li>
<li><b>paramDischargeCurrentLimit</b><br>  Systemparameter Entladestromgrenze (A) des Batteriemoduls                     </li>
<li><b>paramDischargeHighTempLimit</b><br> Systemparameter obere Temperaturgrenze (°C) bis zu der die Batterie entlädt   </li>
<li><b>paramDischargeLowTempLimit</b><br>  Systemparameter untere Temperaturgrenze (°C) bis zu der die Batterie entlädt  </li>
<li><b>paramModuleHighVoltLimit</b><br>    Systemparameter obere Spannungsgrenze (V) des Batteriemoduls                  </li>
<li><b>paramModuleLowVoltLimit</b><br>     Systemparameter untere Spannungsgrenze (V) des Batteriemoduls (Alarmgrenze)   </li>
<li><b>paramModuleUnderVoltLimit</b><br>   Systemparameter Unterspannungsgrenze (V) des Batteriemoduls (Schutzgrenze)    </li>
<li><b>protocolVersion</b><br>             PYLON low voltage RS485 Prokollversion                                        </li>
<li><b>serialNumber</b><br>                Seriennummer                                                                  </li>
<li><b>softwareVersion</b><br>             -----------------------------------                                           </li>
</ul>
<br><br>

=end html_DE

=for :application/json;q=META.json 70_PylonLowVoltage.pm
{
  "abstract": "Integration of pylontech LiFePo4 low voltage batteries (incl. BMS) over RS485 via ethernet gateway (ethernet interface)",
  "x_lang": {
    "de": {
      "abstract": "Integration von Pylontech Niedervolt Batterien (mit BMS) &uumlber RS485 via Ethernet-Gateway (Ethernet Interface)"
    }
  },
  "keywords": [
    "inverter",
    "photovoltaik",
    "electricity",
    "battery",
    "Pylontech",
    "BMS",
    "ESS",
    "PV"
  ],
  "version": "v1.1.1",
  "release_status": "stable",
  "author": [
    "Heiko Maaz <heiko.maaz@t-online.de>"
  ],
  "x_fhem_maintainer": [
    "DS_Starter"
  ],
  "x_fhem_maintainer_github": [
    "nasseeder1"
  ],
  "prereqs": {
    "runtime": {
      "requires": {
        "FHEM": 5.00918799,
        "perl": 5.014,
        "GPUtils": 0,
        "IO::Socket::INET": 0,
        "IO::Socket::Timeout": 0,
        "Errno": 0,
        "FHEM::SynoModules::SMUtils": 1.0220,
        "Time::HiRes": 0,
        "Scalar::Util": 0
      },
      "recommends": {
        "FHEM::Meta": 0
      },
      "suggests": {
      }
    }
  },
  "resources": {
    "x_wiki": {
      "web": "",
      "title": ""
    },
    "repository": {
      "x_dev": {
        "type": "svn",
        "url": "https://svn.fhem.de/trac/browser/trunk/fhem/contrib/DS_Starter",
        "web": "https://svn.fhem.de/trac/browser/trunk/fhem/contrib/DS_Starter/70_PylonLowVoltage.pm",
        "x_branch": "dev",
        "x_filepath": "fhem/contrib/",
        "x_raw": "https://svn.fhem.de/fhem/trunk/fhem/contrib/DS_Starter/70_PylonLowVoltage.pm"
      }
    }
  }
}
=end :application/json;q=META.json

=cut