#A simple interface for consistency in consuming packages
use 5.10.0;
use strict;
use warnings;

package Seq::Tracks::Base::Interface;

use Mouse::Role 2;
use namespace::autoclean;

#every track requires a get method to retrieve all data
requires 'get';

no Mouse::Role;
1;