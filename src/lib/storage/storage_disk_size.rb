#!/usr/bin/env ruby
#
# encoding: utf-8

# Copyright (c) [2015] SUSE LLC
#
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, contact SUSE LLC.
#
# To contact SUSE LLC about this file by physical or electronic mail, you may
# find current contact information at www.suse.com.

require "yast"
require "pp"

# This file can be invoked separately for minimal testing.

module Yast
  module Storage
    #
    # Class to handle disk sizes in the MB/GB/TB range with readable output.
    #
    class DiskSize
      include Yast::I18n
      include Comparable

      attr_accessor :size_k

      def initialize(size_k=0)
        textdomain "storage"
        @size_k = size_k.round
      end

      #
      # Factory methods
      #
      def self.kiB(kb_size)
        DiskSize.new(kb_size)
      end

      def self.MiB(mb_size)
        DiskSize.new(mb_size*1024)
      end

      def self.GiB(gb_size)
        DiskSize.new(gb_size*(1024**2))
      end

      def self.TiB(tb_size)
        DiskSize.new(tb_size*(1024**3))
      end

      def self.PiB(tb_size)
        DiskSize.new(tb_size*(1024**5))
      end

      def self.EiB(tb_size)
        DiskSize.new(tb_size*(1024**6))
      end

      def self.ZiB(tb_size)
        DiskSize.new(tb_size*(1024**7))
      end

      def self.YiB(tb_size)
        DiskSize.new(tb_size*(1024**8))
      end


      #
      # Operators
      #

      def +(other)
        if (other.is_a?(Numeric))
          DiskSize.new(@size_k+other)
        elsif (other.respond_to?(:size_k))
          DiskSize.new(@size_k+other.size_k)
        else
          raise TypeError, "Numeric value or DiskSize expected"
        end
      end

      def -(other)
        if (other.is_a?(Numeric))
          DiskSize.new(@size_k-other)
        elsif (other.respond_to?(:size_k))
          DiskSize.new(@size_k-other.size_k)
        else
          raise TypeError, "Numeric value or DiskSize expected"
        end
      end

      def *(other)
        if (other.is_a?(Numeric))
          DiskSize.new(@size_k*other)
        else
          raise TypeError, "Numeric value expected"
        end
      end

      def /(other)
        if (other.is_a?(Numeric))
          DiskSize.new(@size_k.to_f/other)
        else
          raise TypeError, "Numeric value expected"
        end
      end

      # The Comparable mixin will get us operators < > <= >= == != with this
      def <=>(other)
        if (other.respond_to?(:size_k))
          return @size_k <=> other.size_k
        else
          raise TypeError, "DiskSize expected"
        end
      end

      # Return numeric size and unit ("MiB", "GiB", ...) in human-readable form
      # as array: [size, unit]
      def to_human_readable
        unit = [_("kiB"), _("MiB"), _("GiB"), _("TiB"), _("PiB"), _("EiB"), _("ZiB"), _("YiB")]
        unit_index = 0
        size = @size_k.to_f

        while (size > 1024.0 && unit_index < unit.size-1)
          size /= 1024.0
          unit_index += 1
        end
        [size, unit[unit_index]]
      end

      def to_s
        size, unit = to_human_readable
        "#{'%.2f' % size} #{unit}"
      end
    end
  end
end


if $PROGRAM_NAME == __FILE__  # Called direcly as standalone command? (not via rspec or require)
  size = Yast::Storage::DiskSize.new(42)
  print "42 kiB: #{size} (#{size.size_k} kiB)\n"

  size = Yast::Storage::DiskSize.MiB(43)
  print "43 MiB: #{size} (#{size.size_k} kiB)\n"

  size = Yast::Storage::DiskSize.GiB(44)
  print "44 GiB: #{size} (#{size.size_k} kiB)\n"

  size = Yast::Storage::DiskSize.TiB(45)
  print "45 TiB: #{size} (#{size.size_k} kiB)\n"

  size = Yast::Storage::DiskSize.PiB(46)
  print "46 PiB: #{size} (#{size.size_k} kiB)\n"

  size = Yast::Storage::DiskSize.EiB(47)
  print "47 EiB: #{size} (#{size.size_k} kiB)\n"

  size = Yast::Storage::DiskSize.TiB(48*1024**5)
  print "Huge: #{size} (#{size.size_k} kiB)\n"

  size = Yast::Storage::DiskSize.MiB(12)*3
  print "3*12 MiB: #{size} (#{size.size_k} kiB)\n"

  other_size = size+Yast::Storage::DiskSize.MiB(20)
  print "3*12+20 MiB: #{other_size} (#{other_size.size_k} kiB)\n"

  other_size /= 13
  print "(3*12+20)/7 MiB: #{other_size} (#{other_size.size_k} kiB)\n"

  print "#{size} < #{other_size} ? -> #{size < other_size}\n"
  print "#{size} > #{other_size} ? -> #{size > other_size}\n"
end
