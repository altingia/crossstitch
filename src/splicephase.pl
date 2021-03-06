#!/usr/bin/perl -w
use strict;

## Parameters for overrulling homozygous variant calls
my $OVERRULE_HOMOZYGOUS_FACTOR = 5;
my $OVERRULE_HOMOZYGOUS_MINREADS = 5;

my $PHASE_SVS = 1;
my $SVTOOLONG = 1.2;
my $SVTOOSHORT = 0.8;
my $REPORT_INVALID_LEN_INSERTIONS = 1;
my $MIN_PHASED_SNV = 5;
my $MAX_SV_LEN = 20000;

my $USAGE = "splicephase.pl phased.vcf sniffles.vcf loadreads.hairs spliced.vcf ref.fa\n";

my $PHASEDVCFFILE   = shift or die $USAGE;
my $SNIFFLESVCFFILE = shift or die $USAGE;
my $READHAIRSFILE   = shift or die $USAGE;
my $OUTVCFFILE      = shift or die $USAGE;
my $REFFASTA        = shift or die $USAGE;

open PHASEDVCF,      $PHASEDVCFFILE   or die "Cant open $PHASEDVCFFILE ($!)\n";
open SNIFFLESVCF,    $SNIFFLESVCFFILE or die "Cant open $SNIFFLESVCFFILE ($!)\n";
open READHAIRS,      $READHAIRSFILE   or die "Cant open $READHAIRSFILE ($!)\n";
open OUTVCF,         "> $OUTVCFFILE"  or die "Cant open $OUTVCFFILE ($!)\n";
open READPHASE,      "> $OUTVCFFILE.readphase" or die "Cant open $OUTVCFFILE.readphase ($!)\n";
open SVPHASE,        "> $OUTVCFFILE.svphase"   or die "Cant open $OUTVCFFILE.svphase ($!)\n";
open SVPHASEDETAILS, "> $OUTVCFFILE.svphase.details" or die "Cant open $OUTVCFFILE.svphase.details ($!)\n";


sub rc
{
  my $seq = shift @_;
  $seq = reverse ($seq);
  $seq =~ tr/ACGTacgt/TGCAtgca/;
  return $seq;
}


sub getseq
{
  my $chr = shift @_;
  my $pos = shift @_;
  my $svlen = shift @_;

  my $end = $pos + $svlen;

  my $TMPFILE = ".splicephase.tmp";

  # print "Running samtools faidx $REFFASTA \"$chr:$pos-$end\"\n";
  system("samtools faidx $REFFASTA \"$chr:$pos-$end\" > $TMPFILE");

  open RAW, "$TMPFILE" or die "Cant open ($!)\n";

  my $seq = "";

  while (<RAW>)
  {
    next if (/^>/);
    chomp;
    $seq .= $_;
  }

  system("rm -f $TMPFILE");

  return $seq;
}



## Load the phased VCF file
###############################################################################

my @vcfheader;
my %vcfdata;

my $vcfheaderlines = 0;
my $vcfdatalines = 0;
my %vcfidlookup;

while (<PHASEDVCF>)
{
  chomp;
  if (/^#/) 
  {
    push @vcfheader, $_;
    $vcfheaderlines++;
  }
  else
  {
    $vcfdatalines++;

    my ($chrom, $pos, $id, $ref, $alt, $qual, $filter, $info, $format, $sample) = split /\s+/, $_;
    my $v;
    $v->{chrom}  = $chrom;
    $v->{pos}    = $pos;
    $v->{id}     = $id;
    $v->{ref}    = $ref;
    $v->{alt}    = $alt;
    $v->{qual}   = $qual;
    $v->{filter} = $filter;
    $v->{info}   = $info;
    $v->{format} = $format;
    $v->{sample} = $sample;
    $v->{vcfidx} = $vcfdatalines;

    my ($genotype, $other) = split /:/, $sample;
    $v->{genotype} = $genotype;

    $vcfdata{$chrom}->{$pos} = $v;
    $vcfidlookup{$vcfdatalines} = $v;
  }
}

print "Loaded $vcfheaderlines header lines and $vcfdatalines variants\n";


## Load Sniffles SV calls
###############################################################################

my %readstophase;
my %snifflesvariants;
my %snifflesvarianttypes;
my $sniffleslines = 0;
while (<SNIFFLESVCF>)
{
  if (/^#/) 
  {
    ## nothing to do
  }
  else
  {
    chomp;
    my ($chrom, $pos, $id, $ref, $alt, $qual, $filter, $info, $format, $sample) = split /\s+/, $_;
    my $v;
    $v->{oldalt} = $alt;
    $v->{oldref} = $ref; 
    if (index($info, "SVTYPE=INS") >= 0)
    {
      $alt = "<INS>";
    }
    if (index($info, "SVTYPE=DEL") >= 0)
    {
      $alt = "<DEL>";
    }
    $v->{chrom}  = $chrom;
    $v->{pos}    = $pos;
    $v->{id}     = $id;
    $v->{ref}    = $ref;
    $v->{alt}    = $alt;
    $v->{qual}   = $qual;
    $v->{filter} = $filter;
    $v->{info}   = $info;
    $v->{format} = $format;
    $v->{sample} = $sample;
    $v->{reads}  = [];

    $snifflesvarianttypes{$alt}->{all}++;
    $snifflesvarianttypes{$alt}->{reported} = 0;
    $snifflesvarianttypes{$alt}->{phased} = 0;
    $snifflesvarianttypes{$alt}->{unphased} = 0;

    my ($genotype, $other) = split /:/, $sample;
    $v->{genotype} = $genotype;

    my @infofields = split /;/, $info;
    foreach my $f (@infofields)
    {
      if ($f =~ /^RNAMES=/)
      {
         $f = substr($f, 7);
         my @reads = split /,/, $f;
         foreach my $r (@reads)
         {
           $readstophase{$r}->{num}++;
           $readstophase{$r}->{hap1} = 0;
           $readstophase{$r}->{hap2} = 0;
           $readstophase{$r}->{snps} = "";

           push @{$v->{reads}}, $r;
         }
      }
      elsif ($f =~ /^SEQ=/)
      {
        $v->{seq} = substr($f, 4);
      }
      elsif ($f =~ /^SVLEN=/)
      {
        $v->{svlen} = abs(int(substr($f, 6)));
      }
    }

    $snifflesvariants{$chrom}->{$pos} = $v;
    $sniffleslines++;
  }
}

my $readcount = scalar keys %readstophase;
print "Loaded $sniffleslines sniffles variants involving $readcount reads:";
foreach my $t (sort keys %snifflesvarianttypes)
{
  my $n = $snifflesvarianttypes{$t}->{all};
  print " $t $n";
}
print "\n";


## Determine the read phase information
###############################################################################

my $hairslines = 0;
my $foundhairs = 0;
while (<READHAIRS>)
{
  $hairslines++;
  chomp;
  my @fields = split /\s+/, $_;
  my $rid = $fields[1];

  if (exists $readstophase{$rid})
  {
    $readstophase{$rid}->{hairs}++;
    $foundhairs++ if ($readstophase{$rid}->{hairs} == 1);

    ## Count how many calls for hap1 vs hap2 at informative snps
    my $hap1 = 0; 
    my $hap2 = 0;

    my $blocks = $fields[0];
    for (my $b = 0; $b < $blocks; $b++)
    {
      my $sidx = $fields[2+$b*2];
      my $allelestr = $fields[2+$b*2+1];

      my @alleles = split //, $allelestr;

      for (my $aidx = 0; $aidx < scalar @alleles; $aidx++)
      {
        my $vcfid = $sidx + $aidx;
        my $allele = $alleles[$aidx]; # 0 or 1
        
        ## lookup if this allele corresponds to hap1 or hap2
        my $v = $vcfidlookup{$vcfid};
        my $genotype = $v->{genotype};

        my $chr = $v->{chrom};
        my $pos = $v->{pos};
        my $hap = "A";


        ## Only process the informative genotypes
        if ($genotype eq "0|1")
        {
          if ($allele == 0) { $hap1++; $hap="A"; }
          else              { $hap2++; $hap="B"; }
        }
        elsif ($genotype eq "1|0")
        {
          if ($allele == 1) { $hap1++;  $hap = "A"}
          else              { $hap2++;  $hap = "B"}
        }

        $readstophase{$rid}->{snps} .= " $chr:$pos:$allele:$hap";
      }
    }

    $readstophase{$rid}->{hap1} += $hap1;
    $readstophase{$rid}->{hap2} += $hap2;
  }
}

print "Scanned $hairslines hairs records, loaded $foundhairs of $readcount involved in SVs\n";


## Print phase status of reads to the log file
###############################################################################

print READPHASE "#READID\tNUMSV\t|\tHAP1\tHAP2\t| HAP HAPR | SNPS\n";
foreach my $rid (sort {lc($a) cmp lc($b)} keys %readstophase)
{
  my $numsv = $readstophase{$rid}->{num};
  my $hap1  = $readstophase{$rid}->{hap1};
  my $hap2  = $readstophase{$rid}->{hap2};
  my $hap1r = sprintf("%7.02f  ", ($hap1+$hap2>0) ? 100*$hap1 / ($hap1+$hap2) : 0);
  my $snps  = $readstophase{$rid}->{snps};
  my $hap = ($hap1 >= $hap2) ? "hapA" : "hapB";
  print READPHASE "$rid\t$numsv\t|\t$hap1\t$hap2\t| $hap $hap1r|$snps\n";
}

## Process Sniffles SVs
###############################################################################

print SVPHASE "chr:pos:genotype\ttype\tsvlen\tseqlen\t|\tnumreads\thap1\thap2\t| hap hap1r\t|\tnewgenotype\tincludesv\toverrulehomo\n";
print SVPHASEDETAILS "chr:pos:genotype\ttype\tsvlen\tseqlen\t|\tnumreads\thap1\thap2\t| hap hap1r\t|\tnewgenotype\tincludesv\toverrulehomo\n";

my $reportedsvs = 0;
my $phasedsvs = 0;
my $unphasedsvs = 0;
my $allsniffles = 0;
my $svlenerr = 0;
my $genotypeerr = 0;

foreach my $chr (sort keys %snifflesvariants)
{
  foreach my $pos (sort {$a <=> $b} keys %{$snifflesvariants{$chr}})
  {
    $allsniffles++;
    my $v = $snifflesvariants{$chr}->{$pos};

    my $hap1 = 0;
    my $hap2 = 0;

    my $numreads = 0;

    foreach my $rid (@{$v->{reads}})
    {
      $numreads++;
      $hap1  += $readstophase{$rid}->{hap1};
      $hap2  += $readstophase{$rid}->{hap2};
    }

    my $hap1r = sprintf("%7.02f  ", ($hap1+$hap2>0) ? 100*$hap1 / ($hap1+$hap2) : 0);
    my $hap = ($hap1 >= $hap2) ? "hapA" : "hapB";
    my $genotype = $v->{genotype};
    my $type = $v->{alt};
    my $svlen = $v->{svlen};

    $hap = "hom" if ($genotype eq "1/1");

    print "Analyzing $chr:$pos:$genotype\t$type\t$svlen\t|\t$numreads\t$hap1\t$hap2\t| $hap\t$hap1r\n";

    if (($v->{alt} eq "<INS>") || ($v->{alt} eq "<DEL>") || ($v->{alt} eq "<INV>"))
    {
      if ($svlen <= $MAX_SV_LEN)
      {
        if (($genotype eq "0/0") || ($genotype eq "0/1") || ($genotype eq "1/1"))
        {
          ## phase the genotype call
          my $newgenotype = $genotype;
          my $overrulehomo = 0;
          my $isphased = 0;

          if ($genotype eq "1/1")
          {
            $isphased = 1;
            $newgenotype = "1|1";

            if ($numreads >= $OVERRULE_HOMOZYGOUS_MINREADS)
            {
              if     ($hap2 >= $hap1 * $OVERRULE_HOMOZYGOUS_FACTOR) { $newgenotype = "0|1"; $overrulehomo = 1; }
              elsif  ($hap1 >= $hap2 * $OVERRULE_HOMOZYGOUS_FACTOR) { $newgenotype = "1|0"; $overrulehomo = 1; }
            }
          }
          elsif (($genotype eq "0/1") || ($genotype eq "0/0"))
          {
            if (($hap1 + $hap2) < $MIN_PHASED_SNV)
            {
              $isphased = 0;
              if    ($hap eq "hapA") { $newgenotype = "1/0"; }
              elsif ($hap eq "hapB") { $newgenotype = "0/1"; }
            }
            else
            {
              $isphased = 1;
              if    ($hap eq "hapA") { $newgenotype = "1|0"; }
              elsif ($hap eq "hapB") { $newgenotype = "0|1"; }
            }
          }

          my $slen = 0;
          $slen = length($v->{seq}) if exists $v->{seq};

          foreach my $rid (@{$v->{reads}})
          {
            print SVPHASEDETAILS "== $rid\n";
          }

          my $includesv = 0;

          if ($v->{alt} eq "<DEL>")
          {
            ## Create a dummy string of Xs that are the right length for the deletion
            $v->{ref} = $v->{oldref};
            $v->{alt} = $v->{oldalt};

            $includesv = 1;
          }
          elsif ($v->{alt} eq "<INS>")
          {
              my $seqlen = $v->{svlen};
              my $svlen = $v->{svlen};

              $includesv = 1;

              if (($seqlen < ($SVTOOSHORT * $svlen)) || ($seqlen > ($SVTOOLONG * $svlen)))
              {
                print "WARNING reported insertion sequencing length ($seqlen) significantly differs from reported SV size ($svlen)\n";
                $includesv = $REPORT_INVALID_LEN_INSERTIONS;;
                $svlenerr++;
              }
          }
          elsif ($v->{alt} eq "<INV>")
          {
            $v->{ref} = "X" x $svlen;
            $v->{alt} = rc(getseq($chr, $pos, $svlen));
            $includesv = 1;
          }

          print SVPHASE "$chr:$pos:$genotype\t$type\t$svlen\t$slen\t|\t$numreads\t$hap1\t$hap2\t| $hap\t$hap1r\t|\t$newgenotype\t$includesv\t$overrulehomo\n";
          print SVPHASEDETAILS "$chr:$pos:$genotype\t$type\t$svlen\t$slen\t|\t$numreads\t$hap1\t$hap2\t| $hap\t$hap1r\t|\t$newgenotype\t$includesv\t$overrulehomo\n";

          if ($includesv && $PHASE_SVS)
          {
            # Now update the variant phase and splice into the others
            substr($v->{sample}, 0, 3) = $newgenotype;
            $vcfdata{$chr}->{$pos} = $v;
            $reportedsvs++;

            $snifflesvarianttypes{$type}->{reported}++;

            if ($isphased)
            {
              $snifflesvarianttypes{$type}->{phased}++;
              $phasedsvs++;
            }
            else
            {
              $snifflesvarianttypes{$type}->{unphased}++;
              $unphasedsvs++;
            }
          }
        }
        else
        {
          print "ERROR: Weird genotype call: $type $genotype\n";
          $genotypeerr++;
        }
      }
      else
      {
        print "ERROR: extreme SV length reported: $type $svlen\n";
        $genotypeerr++;
      }
    }
  }
}

print "Reported $reportedsvs, phased $phasedsvs, unphased: $unphasedsvs of $allsniffles attempted ($sniffleslines all). svlenerr: $svlenerr genotyperr: $genotypeerr\n";
print "type all reported phased unphased:";

foreach my $t (sort keys %snifflesvarianttypes)
{
  my $n = $snifflesvarianttypes{$t}->{all};
  my $r = $snifflesvarianttypes{$t}->{reported};
  my $p = $snifflesvarianttypes{$t}->{phased};
  my $u = $snifflesvarianttypes{$t}->{unphased};
  print " $t $n $r $p $u";
}
print "\n";


## Print output
###############################################################################

# Print the old header
foreach my $h (@vcfheader)
{
  print OUTVCF "$h\n";
}

# Now print the updated variants
foreach my $chrom (sort keys %vcfdata)
{
  foreach my $pos (sort {$a <=> $b} keys %{$vcfdata{$chrom}})
  {
    my $v = $vcfdata{$chrom}->{$pos};

    my $id     = $v->{id};
    my $ref    = $v->{ref};
    my $alt    = $v->{alt};
    my $qual   = $v->{qual};
    my $filter = $v->{filter};
    my $info   = $v->{info};
    my $format = $v->{format};
    my $sample = $v->{sample};

    print OUTVCF "$chrom\t$pos\t$id\t$ref\t$alt\t$qual\t$filter\t$info\t$format\t$sample\n";
  }
}
