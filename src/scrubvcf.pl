#!/usr/bin/perl -w
use strict;

my $STRIP_OVERLAP = 0;

## Only report variants on chr1 - chr22, chrX, chrY
my %chrom;
for (my $i = 1; $i <= 22; $i++)
{
  $chrom{"chr$i"} = 0;
  $chrom{"$i"} = 0;
}

$chrom{"chrX"} = 0;
$chrom{"X"} = 0;
$chrom{"chrY"} = 0;
$chrom{"Y"} = 0;

## Types to report
my %types;
$types{"<INS>"} = 0;
$types{"<DEL>"} = 0;
$types{"<INV>"} = 0;

if (scalar @ARGV > 0)
{
  if ($ARGV[0] eq "-h")
  {
    print "USAGE: scrubvcf.pl [-o male|female] orig.vcf > new.vcf\n";
    print "\n";
    print " By default, scrub variants that arent on chr1-22, chrX, chrY or are not INS, DEL, INV\n";
    print "\n";
    print " In -o mode, remove any overlapping variants or variants not on chr1-22, chrX, chrY (if gender = female)\n";
    print "             but DONT scrub any variant types\n";

    exit(0);
  }
  elsif ($ARGV[0] eq "-o")
  {
    $STRIP_OVERLAP = 1;
    shift @ARGV;
    my $gender = shift @ARGV or die "Must specific a gender (male or female) when stripping overlapping variants\n";
    print STDERR "stripping overlapping calls (gender = $gender)\n";

    if    ($gender eq "male")   { }  ## nothing to do 
    elsif ($gender eq "female") { delete $chrom{"chrY"}; }
    else  { die "Unknown gender: $gender\n"; }
  }
}


my $all = 0;
my $reported = 0;

my $lastchr = undef;

my $lastpos0 = -1; my $lastref0 = ""; my $lastalt0 = ""; my $lastline0 = undef; my $lastsniffles0 = 0; 
my $lastpos1 = -1; my $lastref1 = ""; my $lastalt1 = ""; my $lastline1 = undef; my $lastsniffles1 = 0;
my $lasthomo = 0;

while (<>)
{
  if ($_ =~ /^#/) { print $_; }
  else
  {
    $all++;

    my @fields   = split /\s+/, $_;
    my $chr      = $fields[0];
    my $pos      = $fields[1];
    my $id       = $fields[2];
    my $ref      = $fields[3];
    my $alt      = $fields[4];
    my $qual     = $fields[5];
    my $filter   = $fields[6];
    my $info     = $fields[7];
    my $genotype = (split (/:/, $fields[9]))[0];

    if ($STRIP_OVERLAP)
    {
      if ($filter ne "PASS")
      {
        $types{"FAIL_PASS"}++;
        next;
      }

      if (!exists $chrom{$chr})
      {
        $types{"FAIL_CHROM"}++;
        next;
      }

      ## see if we can print the last variants because we have moved to a different chromosome or moved passed them
      if (defined $lastchr)
      {
        if ($lastchr ne $chr)
        {
          if (defined $lastline0) { print $lastline0; $lastline0 = undef; if ($lasthomo) { $lastline1 = undef; }}
          if (defined $lastline1) { print $lastline1; $lastline1 = undef; }

          ## totally reset between chromosomes
          $lastpos0 = -1; $lastref0 = ""; $lastalt0 = ""; $lastline0 = undef; $lastsniffles0 = 0; 
          $lastpos1 = -1; $lastref1 = ""; $lastalt1 = ""; $lastline1 = undef; $lastsniffles1 = 0;
          $lasthomo = 0;
        }
        else
        {
          ## reset lastline and other state varianbles
          if ((defined $lastline0) && ($pos > $lastpos0)) { print $lastline0; $lastline0 = undef; $lastsniffles0 = 0; if ($lasthomo) { $lastline1 = undef; $lastsniffles1 = 0; $lasthomo = 0; } }
          if ((defined $lastline1) && ($pos > $lastpos1)) { print $lastline1; $lastline1 = undef; $lastsniffles1 = 0; }
        }
      }

      my $printvar = 1;

      my $type = "SUB";
      if    (length($ref) < length($alt)) { $type = "INS"; }
      elsif (length($ref) > length($alt)) { $type = "DEL"; }

      my $hap = 2; ## all unphased genotypes and 1|1 are on both haplotypes
      if    ($genotype eq "0|1") { $hap = 1; }
      elsif ($genotype eq "1|0") { $hap = 0; }

      my $issniffles = 0;
      if (index($info, "Sniffles") >= 0) { $issniffles = 1; }

      if ((defined $lastchr) && ($chr eq $lastchr))
      {
        if (($hap == 0) || ($hap == 2)) 
        { 
          if ($pos <= $lastpos0) 
          { 
            if ($issniffles && !$lastsniffles0)
            {
               ## rescued
               $types{"OVERRULE_$hap"}++;
               $lastline0 = undef; if ($lasthomo) { $lastline1 = undef; $lastpos1 = -1; }
               print STDERR " overrule overlap detected 1 on hap $hap (lastpos: $lastpos0 @ $lastchr $lastref0 $lastalt0) at $_"; 
            }
            else
            {
              $printvar = 0; 
              $types{"FAIL_$hap"}++; 
              if ($issniffles) { $types{"FAIL_SNIFFLES_$hap"}++; }
              print STDERR " overlap detected 1 on hap $hap (lastpos: $lastpos0 @ $lastchr $lastref0 $lastalt0) at $_"; 
            } 
          }
        }

        if ($printvar)
        {
          if (($hap == 1) || ($hap == 2)) 
          { 
            if ($pos <= $lastpos1) 
            { 
              if ($issniffles && !$lastsniffles1)
              {
                ## rescued
                $types{"OVERRULE_$hap"}++;
                $lastline1 = undef; if ($lasthomo) { $lastline0 = undef; $lastpos0 = -1; }
                print STDERR " overrule overlap 2 detected on hap $hap (lastpos: $lastpos1 @ $lastchr $lastref1 $lastalt1) at $_"; 
              }
              else
              {
                $printvar = 0; 
                $types{"FAIL_$hap"}++; 
                if ($issniffles) { $types{"FAIL_SNIFFLES_$hap"}++; }
                print STDERR " overlap detected 2 on hap $hap (lastpos: $lastpos1 @ $lastchr $lastref1 $lastalt1) at $_"; 
              }
            } 
          }
        }
      } 

      if ($printvar)
      {
        $reported++;
        $types{$type}++;
        #print $_; ## Dont print right away, since there might be a sniffles SV next

        $lastchr = $chr;

        my $newpos = $pos + length($ref) - 1;

        if (($hap == 0) || ($hap == 2)) { $lastpos0 = $newpos; $lastref0 = $ref; $lastalt0 = $alt; $lastline0 = $_; $lastsniffles0 = $issniffles; }
        if (($hap == 1) || ($hap == 2)) { $lastpos1 = $newpos; $lastref1 = $ref; $lastalt1 = $alt; $lastline1 = $_; $lastsniffles1 = $issniffles; }

        if ($hap == 2) { $lasthomo = 1; } else { $lasthomo = 0; }
      }
    }
    else
    {
      if (index($info, "SVTYPE=INS") >= 0)
      {
        $alt = "<INS>";
      }
      if (index($info, "SVTYPE=DEL") >= 0)
      {
        $alt = "<DEL>";
      }
      if (exists $chrom{$chr} && exists $types{$alt})
      {
        $reported++;
        $types{$alt}++;
        print $_;
      }
    }
  }
}

if (defined $lastline0) { print $lastline0; $lastline0 = undef; if ($lasthomo) { $lastline1 = undef; }}
if (defined $lastline1) { print $lastline1; $lastline1 = undef; }


print STDERR "## Reported $reported of $all variants:\n";
foreach my $t (sort keys %types)
{
  my $n = $types{$t};
  print STDERR "$t $n\n";
}
