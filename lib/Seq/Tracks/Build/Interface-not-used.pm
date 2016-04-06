#NOT currently used
use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Build::Interface;

use Moose::Role;
use namespace::autoclean;

requires 'buildTrack';

no Moose::Role;
1;