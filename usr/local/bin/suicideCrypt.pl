#!/usr/bin/perl -w

# suicideCrypt.pl : Creates plausibly intrustion and theft proof encrypted volumes.
# Author          : Sebastian Kai Frost
# Created On      : Monday 25th September 2017
# Status          : Released
# requirements    : At least 4 gig of RAM, and enough space on local volumes to 
#                 : hold any container of the size you wish to create. 

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case);

### Editable Globals ###

my $DEBUG = 0;
my $VERBOSE = 0;
my $VERSION = "0.1";
my $RAMDISK = "/tmp/suicideCryptRAMdisk";
my $LOGFILE = "/var/log/suicideCrypt.log";
my $LOG;
my %CMDOPTIONS = ();
my $cryptID = randString();

### Begining of main program ###

parseOptions();

if (defined $CMDOPTIONS{v}) {
  $VERBOSE = 1; # set verbose 
}

# Choose what to execte.
if (defined $CMDOPTIONS{h}) {
  printHelp();
  exit(1);
} elsif (defined $CMDOPTIONS{c}) {
  logStart("Create");
  create();
  logClose();
  exit(1);
} elsif (defined $CMDOPTIONS{l}) {
  listsuicideCryptVol();
  exit (1);
} elsif (defined $CMDOPTIONS{d}) {
  logStart("Destroy");
  destroy($CMDOPTIONS{d});
  logClose();
  exit (1);
} elsif (defined $CMDOPTIONS{D}) {
  logStart("DestroyAll");
  destroyAll();
  logClose();
  exit(1);
}

printHelp();

### Begin subs ###

### Kicks off the logger for full execution trail
sub logStart {
  my $msg = shift;

  open($LOG, '>>', $LOGFILE) or die "Could not open logfile '$LOGFILE' $!";
  $msg = "\n -> Opening Log file to begin a " . "$msg" . " event\n";
  printLC($msg, $VERBOSE);
}

### Closes logger 
sub logClose {

  printLC("-> Operation complete closing logfile $LOGFILE\n", $VERBOSE);
  close $LOG;

}

### Parses all command line options and creates a global command hash
sub parseOptions {

  GetOptions ( \%CMDOPTIONS,
            "c|create",    
            "l|list",
            "v|verbose",
            "d|destroy:s",
            "D|destroyall",
            "p|paranoid",
            "y|yes",
            "h|help")
  or die("Error in command line arguments\n");
}

### Create a suicideCrypt volume
sub create {

  my %createoptions;
  my $mountpoint;

  %createoptions = getOptions(); # gather user requirements
  $mountpoint = $createoptions{'mountpoint'};
  print "\nWe are now ready to create your encrypted volume with the following options:\n";
  printOptions(%createoptions); # show the user their choices for conformation before execution 
  if (yN()) {
    printLC("-> Creating the requested volume...\n", 1);
    createTMPfs();
    createKeyFile();
    createHeaderFile();
    if ($createoptions{'type'} eq "c") { 
      createContainer(%createoptions); # Create an encrypted container
    } elsif ($createoptions{'type'} eq "d") {
      createVolume(%createoptions); # Create an encypted blcok device
    }
    ### The core of suicideCrypt. If you select paranoid mode a key and Headr are generated
    ### for just long enought to encrypt and mount the volume then are destroyed forever. 
    ### this results in a mounted drive that can never be recovered once unmounted or the 
    ### server is rebooted. All of this is logged extensivly as a audit trail. 
    if ($createoptions{'paranoid'}) {
      printLC("  -> Paranoid mode selected, deleting header and LUKS keyfile.\n", 1);
      printLC("  -> !! After this point, volume will be unrecoverable after reboot or unmount !!\n", 1);
      printLC("  -> Zeroing LUKS header file...\n", $VERBOSE);
      removeHdrKey($cryptID);
    }
    printLC("-> Success, volume is now mounted on $mountpoint\n", 1);
  } else { 
    printLC("Aborting create...\n", 1);
  }
} 

### zero and delete a LUKs header and suicideCrypt keyfile. 
sub removeHdrKey {
	
  my $id = shift;

  printLC("  -> Zeroing LUKS header file...\n", $VERBOSE);
  zeroFile("$RAMDISK/lukshdr-$id");
  sleep 1;
  printLC("  -> Done zeroing LUKS header.\n", $VERBOSE);
  printLC("  -> Zeroing keyfile....\n", $VERBOSE);
  zeroFile("$RAMDISK/keyfile-$id");
  sleep 1;
  printLC("  -> Done Zeroing keyfile.\n", $VERBOSE);
  printLC("  -> Unlinking files...\n", $VERBOSE);
  unlink("$RAMDISK/lukshdr-$id");
  unlink("$RAMDISK/keyfile-$id");
  printLC("  -> Done unlinking LUKS header and keyfile.\n", $VERBOSE);
  if (is_folder_empty($RAMDISK)) {
    printLC("  -> RAMDISK is empty, no more volumes, unmounting and deleting $RAMDISK\n", $VERBOSE);
    system("umount $RAMDISK");
    rmdir($RAMDISK);
    printLC("  -> Done unmounting and deleting $RAMDISK\n", $VERBOSE);
  }
}

### destroy a suicideCrypt drive, can take a mount point, mapper refrence,
### or if nothing given lets the user select from a list.
sub destroy {

  my $volume = shift;
  my $select;
  my %allVols = getMounted();
  my $valid = 0;
  my @volNum = keys(%allVols);
  my $val;
  my @destroyVol;

  if (!@volNum) {
    printLC("No suicideCrypt volumes detected mounted on this host, doing nothing\n", 1);
    exit(1);
  }
  if (!$volume) {
    print "\nNo volume specified, Please choose which mounted volume to destroy from this list:\n";
    listsuicideCryptVol();
    while (!$valid) {
      print "Enter number of volume you wish to destroy: ";
      $select = <STDIN>;
      chomp($select);
      foreach $val (@volNum) {
        if ($select =~ m/$val/) {
          $valid = 1;
        } 
      }
      if ($valid) {
        push @destroyVol, $select;
        destroyVolumes(@destroyVol);
      } else {
        print "Invalid selection, please select an existing volume from the list\n"; 
      }
    }
  } else {
    foreach $val (@volNum) {
      if (($volume =~ $allVols{$val}{'mapper'}) || ($volume =~ $allVols{$val}{'mountpoint'})) {
        print "\nVALID suicideCrypt volume\n";
        push @destroyVol, $val;
        destroyVolumes(@destroyVol);
        exit(1);
      }
    }
    print "\nYou have not specified a valid mounted suicideCrypt mapper refrence or mountpoint\n\n";
  }  
}

### Destroy all suicideCrypt drives that the script can detect. If you've unmounted a drive manually
### then you may be screwed as this will not detect the drive and as such not delete and key or 
### header files in ramdisk. Don't do that. 
sub destroyAll {

  my %allVols = getMounted();
  my @volNum = keys(%allVols);  


  if (!@volNum) {
    print "\nNo suicideCrypt volumes detected mounted on this host, doing nothing\n\n";
    exit(1);
  } 
  print "\nYou have chosen to destroy ALL detectable mounted suicideCrypt volumes on this host!\n";
  if (yN()) {
    printLC("\n-> Destroying all detectable mounted suicideCrypt Volumes\n", 1);
    destroyVolumes(@volNum);
    printLC("-> Done\n", 1);
  } else { 
    printLC("-> Aborted!\n", 1);
  }

}

### Sub that actually takes a list of volumes and deletes them.
sub destroyVolumes {

  my @destroyVols = @_;
  my %allVols = getMounted();
  my $vol;
  my @temp;
  my $mapper;
  my $id;

  foreach $vol (@destroyVols) {
    $mapper = $allVols{$vol}{'mapper'};
    @temp = split('-', $mapper);
    $id = $temp[1];
    printLC("-> Destroying sucideCrypt volume $mapper\n", $VERBOSE);
    printLC("  -> Umounting $allVols{$vol}{'mountpoint'}\n", $VERBOSE);
    system ("umount $mapper");
    printLC("  -> Done unmounting $mapper.\n", $VERBOSE);
    printLC("  -> Closing LUKS Crypt volume $mapper\n", $VERBOSE);
    system("cryptsetup close $mapper");
    printLC("  -> Done closing LUKS Volume $mapper\n", $VERBOSE);
    if (!($mapper =~ m/PARANOID/)) {
      printLC("  -> Deleting LUKS Header and keyfiles from $RAMDISK\n", $VERBOSE);
      removeHdrKey($id);
      printLC("  -> Done destroying suicideCrypt volume\n", $VERBOSE);
    } else {
      printLC("  -> Paranoid mode volume, no headers or keyfiles to delete\n", $VERBOSE);
    }
    printLC("-> SuicideCrypt volume $mapper is destroyed and unrecoverable\n", 1);
  }
}

### list all mounted suicideCrypt volumes. 
sub listsuicideCryptVol {

  my %volumes;
  my $key;

  %volumes = getMounted();

  if (!%volumes) {
    print "\nNo mounted suicideCrypt Volumes found\n\n";
  } else {
    print "\n";
    foreach my $key (sort(keys %volumes)) {
      print "$key: $volumes{$key}{'mapper'} on $volumes{$key}{'mountpoint'}\n";
   
    }
    print "\n";
  }

}

### Get a list of all mounted suicideCrypt volumes. Finds them in /proc/mounts
### so if you manually unmount the drive we will not find them. 
sub getMounted {

  my $fh;
  my $line;
  my @temp;
  my %vols;
  my $count = 1;

  open ($fh, '<', "/proc/mounts");
  while ($line = <$fh>) {
    if ($line =~ "suicideCrypt-") {
      @temp = split(' ', $line);
      $vols{$count}{'mapper'} = $temp[0];
      $vols{$count}{'mountpoint'} = $temp[1];
      $count++;
    }
  }
  close ($fh); 
  return %vols;

}

### Create an empty header file for cryptsetup to write to that isn't built into the volume.
### important for suicideCrypt as the header contains the decryption key we want to 
### destroy in the event of compromise/theft of server etc. 
sub createHeaderFile {

  my $cmd = "dd if=/dev/zero bs=4049600 count=1 of=$RAMDISK/lukshdr-$cryptID >/dev/null 2>&1";

  printLC("  -> Creating an empty LUKS header file for the volume: $RAMDISK/lukshdr-$cryptID\n", $VERBOSE);
  system ($cmd);
  printLC("  -> Success creating LUKS Header\n", $VERBOSE);
  return (1);

}

### Create an randomised 4096 byte keyfile to encrypt the volumes with important for suicideCrypt as 
### the user never knows the content of this key. Once it is deleted in the audit trail. The user 
### no longer has the ability to decrypt this volume. We use /dev/urandom here. But for true 
### cryptographic strength the user should use a source of true random data such as a hardware
### random number generator
sub createKeyFile {

  my $cmd = "dd if=/dev/urandom of=$RAMDISK/keyfile-$cryptID bs=4096 count=4 >/dev/null 2>&1";

  printLC("  -> Creating the random keyfile for the volume: $RAMDISK/keyfile-$cryptID\n", $VERBOSE);
  system ($cmd);
  printLC("  -> Success creating keyfile\n", $VERBOSE);
  return (1);

}

### simple yes/no call.
sub yN {

  my $selection;
  my $valid;

  if ($CMDOPTIONS{y}) {
    return 1;
  }
  print "Are you sure you wish you do this? Type YES in capitals to continue (any other key to abort): ";
  $selection = <STDIN>;
  chomp($selection);
  if ($selection eq "YES") {
    return 1;
  } else { 
    return 0;
  }  
}

### print out the options the user chose when prompted before execution. 
sub printOptions {
  
  my (%options) = @_;
  my $type = $options{'type'};
  my $size;
  my $location;
  my $unit;
  my $paranoid = $options{'paranoid'};
  my $mountpoint = $options{'mountpoint'};
  my $device;

  if ($type eq "c") {
    $location = $options{'location'};
    $size = $options{'size'} . $options{'unit'};
    print "## Type:               Container\n";
    print "## Container Location: $location\n";
    print "## Size:               $size\n";
  } elsif ($type eq "d") {
    $device = $options{'device'};
    print "## Type:               Block Device\n";
    print "## Block Device:       $device\n";
  }
  print "## Mount point:        $mountpoint\n";
  print "## Keyfile:            4096 bytes of random data\n";
  print "## Cipher:             AES256\n";
  print "## Paranoid Mode:      ";
  if ($paranoid) {
    print "yes\n";
  } else { 
    print "no\n";
  }
}

sub createTMPfs {

  my $cmd = "mount -t tmpfs -o size=512m tmpfs $RAMDISK";
  my $fh;
  my $line;
  my $found = 0;

  printLC("  -> Creating ramdisk for LUKS header and keyfile...\n", $VERBOSE);
  if (-d $RAMDISK) {
    printLC("    -> $RAMDISK already exisits, assuming previous suicideCrypt use on running system and continuing...\n", $VERBOSE);
  } else { 
    printLC("    -> creating ram disk mount point: $RAMDISK\n", $VERBOSE); 
    unless(mkdir $RAMDISK) {
      die "Unable to create ram disk : $RAMDISK\n";
    }
    printLC("    -> Success creating ramdisk mount point\n", $VERBOSE);
  }
  # Lets check if there is a suicideCrypt ramdisk already mounted.
  open ($fh, '<', "/proc/mounts");
  while ($line = <$fh>) {
    if ($line =~ "suicideCryptRAMdisk") {
      $found = 1;
    } else {
      #do nothing
    }
  }
  close ($fh);
  if ($found) {
    printLC("    -> Found exisitng mounted suicideCrypt ramdisk, assuming exisitng suicideCrypt devices and continuing...\n", $VERBOSE);
  } else {
    printLC("    -> Mounting 512m ramdisk on $RAMDISK.\n", $VERBOSE);
    system($cmd);
    printLC("    -> Success mounting ramdisk\n", $VERBOSE);
  }
  printLC("  -> ramdisk creation Success.\n", $VERBOSE);
}

sub createContainer { 

  my (%options) = @_;
  my $paranoid = $options{'paranoid'};
  my $cryptFileName;
  if ($paranoid) {
    $cryptFileName = "suicideCrypt-PARANOID-$cryptID";
  } else {
    $cryptFileName = "suicideCrypt-$cryptID";
  }
  my $size = $options{'size'};
  my $unit = $options{'unit'};
  my $location = $options{'location'};
  my $mountpoint = $options{'mountpoint'};
  my $containerCmd = "dd if=/dev/zero of=$location/$cryptFileName.img bs=1 count=0 seek=$size$unit >/dev/null 2>&1";
  my $cryptSetupCmd = "cryptsetup luksFormat -s 512 --batch-mode $location/$cryptFileName.img --header $RAMDISK/lukshdr-$cryptID $RAMDISK/keyfile-$cryptID";
  my $cryptOpenCmd = "cryptsetup luksOpen $location/$cryptFileName.img $cryptFileName --key-file $RAMDISK/keyfile-$cryptID --header $RAMDISK/lukshdr-$cryptID";
  my $cryptFmtCmd  = "mkfs.ext4 /dev/mapper/$cryptFileName >/dev/null 2>&1";
  my $mntCmd = "mount /dev/mapper/$cryptFileName $mountpoint";
  my $result;

  printLC("  -> Creating blank container file for LUKS...\n", $VERBOSE);
  # TODO verify that container was created correctly. 
  system($containerCmd);
  printLC("  -> Success creating blank container\n", $VERBOSE);
  printLC("  -> Using Cryptsetup to encrypt container file...\n", $VERBOSE);
  system($cryptSetupCmd);
  printLC("  -> Success encrypting container\n", $VERBOSE);
  printLC("  -> Opening the Encrypted container and creating /dev/mapper link...\n", $VERBOSE);
  system ($cryptOpenCmd);
  printLC("  -> Success creating /dev/mapper/$cryptFileName\n", $VERBOSE);
  printLC("  -> Formatting the unencrypted container EXT4, this may take a while depending on container size...\n", $VERBOSE);
  system($cryptFmtCmd);
  printLC("  -> Success formatting container\n", $VERBOSE);
  printLC("  -> Mounting your encrypted container on $mountpoint...\n", $VERBOSE);
  system($mntCmd);
  printLC("  -> Success mounting container\n", $VERBOSE);
  
}

sub createVolume {

  my (%options) = @_;
  my $paranoid = $options{'paranoid'};
  my $cryptFileName;
  if ($paranoid) {
    $cryptFileName = "suicideCrypt-PARANOID-$cryptID";
  } else {
    $cryptFileName = "suicideCrypt-$cryptID";
  }
  my $mountpoint = $options{'mountpoint'};
  my $device = $options{'device'};
  my $cryptSetupCmd = "cryptsetup luksFormat -s 512 --batch-mode $device --header $RAMDISK/lukshdr-$cryptID $RAMDISK/keyfile-$cryptID";
  my $cryptOpenCmd = "cryptsetup luksOpen $device $cryptFileName --key-file $RAMDISK/keyfile-$cryptID --header $RAMDISK/lukshdr-$cryptID";
  my $cryptFmtCmd  = "mkfs.ext4 /dev/mapper/$cryptFileName >/dev/null 2>&1";
  my $mntCmd = "mount /dev/mapper/$cryptFileName $mountpoint";

  printLC("  -> Using cryptsetup to encrypt the block device $device...\n", $VERBOSE);
  system($cryptSetupCmd);
  printLC("  -> Success encrypting block device\n", $VERBOSE);
  printLC("  -> Opening the Encrypted container and creating /dev/mapper link...\n", $VERBOSE);
  system ($cryptOpenCmd);
  printLC("  -> Success creating /dev/mapper/$cryptFileName\n", $VERBOSE);
  printLC("  -> Formatting the unencrypted volume EXT4, this may take a while depending on container size...\n", $VERBOSE);
  system($cryptFmtCmd);
  printLC("  -> Success formatting volume\n", $VERBOSE);
  printLC("  -> Mounting your encrypted volume on $mountpoint...\n", $VERBOSE);
  system($mntCmd);
  printLC("  -> Success mounting volume\n", $VERBOSE);
 
}


sub getOptions {

  my %options;

  print "\n*** Welcome to suicideCrypt $VERSION.*** \n\n";
  print "First we need to gather a few details about the volume you wish to create;\n\n";
 
  $options{'type'} = getType();
  if ($options{'type'} eq "c") {
    ($options{'size'}, $options{'unit'}) = getSize();
    $options{'location'} = getLocation();
  } elsif ($options{'type'} eq "d") {
    $options{'device'} = getDevice();
  }
  $options{'mountpoint'} = mountPoint();
  $options{'paranoid'} = getParanoid();

  return %options;
}

sub getParanoid {
  
  my $paranoid;
  my $selection;
  my $valid = 0;

  if ($CMDOPTIONS{p}) {
    $paranoid = 1;
    return $paranoid;
  }
  while (!$valid) {
    print "\nDo you want to create this suicideCrypt volume in PARANOID mode?\nEnter 'h' for info on Paranoid mode (y/n/h): ";
    $selection = <STDIN>;
    chomp $selection;
    if ($selection eq "y") {
      $paranoid = 1;
      $valid = 1;
    } elsif ($selection eq "n") {
      $paranoid = 0;
      $valid = 1;
    } elsif ($selection eq "h") {
      print "\n\n** Blah Blah on pranoid mode! ** \n\n";
    } else {
      print "\n!! You have entered an invalid option, please try again !!\n";
    }
  }
  return $paranoid;
}

sub mountPoint { 

  my $selection;
  my $valid = 0;
   my $mp = "";

  while (!$valid) {
    print "\nPlease enter the location on the filesytem that you would like to mount the encrypted volume, eg /mnt: ";
    $selection = <STDIN>;
    chomp $selection;
    if ((-d $selection) && is_folder_empty($selection) ) {
      $mp = $selection;
      $valid = 1;
    } else { 
      print "\n!! You have enterd an invlaid mount point, either the directory doesn't exist or isn't empty. Please try again !!\n";
    }
  }
  return $mp;
}


sub getDevice {

  my $selection;
  my $valid = 0;
  my $device = "";

  while (!$valid) {
    print "\nPlease enter the full path of the block device you wish to encrypt, ie. /dev/sdb, /dev/sdc1: ";
    $selection = <STDIN>;
    chomp $selection;
    if (-e $selection) {
      $device = $selection;
      $valid = 1;
    } else { 
      print "$selection is not a valid block device! Please re-enter a valid device\n";
    }
  }
  return $device;
}

sub getLocation {

  my $selection;
  my $valid = 0;
  my $location = "";
  

  while (!$valid) {
    print "\n** NB: Please ensure there is enough space on the filesystem to hold the size container you specify **";
    print "\nPlease enter the location on the local filesystem you would like to place the encrypted container file: ";
    $selection = <STDIN>;
    chomp $selection;
    if (-d $selection) {
      $location = $selection;
      $valid = 1;
    } else {
      print "This is not a valid location. Please enter a valid location on the local filesystem\n";
    }
  }
  return $location;
}

sub getSize {
  my $selection;
  my $valid = 0;
  my $size;
  my $unit;

  while (!$valid) {
    print "\nPlease enter the size of the container you wish to create in megabytes or gigabytes (e.g, 500M or 5G):";
    $selection = <STDIN>;
    chomp($selection);
    $unit = chop($selection);
    if (($unit eq "G") || ($unit eq "M")) {
      $size = $selection;
      $valid = 1;
    } else {
      print "Invalid unit or size, please try again\n";
    }
  }
  return($size, $unit);
}

sub getType {

  my $selection;
  my $valid = 0;
  my $type;

  while (!$valid) {
    print "Do you wish to create an encrypted (c)ontainer file? Or an encypted physical (d)isk? (c/d): ";
    $selection = <STDIN>;
    chomp($selection);
    if ($selection eq "c") {
      $type = "c";
      $valid = 1;
    } elsif ($selection eq "d") {
      $type = "d";
      $valid = 1;
    }
  }
  return $type;
}



# Generates a random 16 digit string to concatonate to the name of a suicideCrypt volume to prevent collision of multiple volumes.
sub randString {

  my @chars;
  my $string;

  @chars = ("A".."Z", "a".."z", "0".."9");
  $string .= $chars[rand @chars] for 1..16;
  return $string;
}

sub is_folder_empty {
  my $dirname = shift;

  opendir(my $dh, $dirname) or die "Not a directory";
  return scalar(grep { $_ ne "." && $_ ne ".." } readdir($dh)) == 0;

}

sub zeroFile {

  my $filename =  shift;
  my $size;
  my $cmd;  

  $size = -s $filename;

  $cmd = "dd if=/dev/zero of=$filename bs=$size count=1 >/dev/null 2>&1";
  system($cmd);
  return (1);

}

sub printHelp {

  printVer();
  print "Usage:\n";
  print "-c : create an encrypted volume\n";
  print "-l : List all suicideCrypt created volumes\n";
  print "-d <volume, or leave blank for list> : Destroy an encrypted volume.\n";
  print "-D : Destroy all detectable suicideCrypt volumes on this host.\n";
  print "-p : default to paranoid mode in all volume creations.\n";
  print "-y : assume \"yes\" to all destroy/create confirmations. WARNING: You can delete a lot of data this way!\n";
  print "-v : verbose, display more detail on execution.\n";
  print "-h : Display this text.\n\n"; 

}

sub printLC {

  my $msg = shift;
  my $show = shift;
  my @temp;
  my $logmsg;
  my $timestamp = scalar localtime();  

  @temp = split('> ', $msg);
  $logmsg = $temp[1];

  if ($show) {
    print "$msg";
  }
  print $LOG "$timestamp : $logmsg";

}

sub printVer {

  print "\nsucicideCrypt version $VERSION\n\n";

}

### EOF ###