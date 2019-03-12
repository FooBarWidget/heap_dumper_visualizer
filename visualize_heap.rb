#!/usr/bin/env ruby
# frozen_string_literal: true
require 'oily_png'
require 'erb'

module HeapVisualizer
  PAGE_SIZE = 4096
  PAGE_SIZE_MASK = PAGE_SIZE - 1
  BLOCK_SIZE = 16

  class Heap < Struct.new(:number, :addr, :size, :chunks, :pages, :page_dirtiness)
    def initialize(*args)
      super
      self.chunks ||= []
      self.pages ||= []
      self.page_dirtiness ||= {}
    end

    def maybe_dirty_pages
      pages.find_all { |p| p.maybe_dirty? }
    end

    def clean_pages
      pages.find_all { |p| !p.maybe_dirty? }
    end
  end

  class Chunk < Struct.new(:heap, :addr, :number, :size, :type, :preview)
    def offset
      addr - heap.addr
    end
  end

  class Page < Struct.new(:heap, :addr, :dirty, :blocks)
    def initialize(*args)
      super
      self.blocks ||= []
    end

    def maybe_dirty?
      dirty != false # considering nil too, which means 'unknown'
    end
  end

  class Block < Struct.new(:page, :chunk, :addr, :number, :end_of_chunk)
    def heap
      page.heap
    end

    def end_of_chunk?
      end_of_chunk
    end

    def used?
      chunk.type == :used
    end
  end

  # Given a heaps_chunk.log, parses the file into data structures
  # that represent the heaps and the containing chunks.
  class HeapChunksLogParser
    attr_reader :heaps

    def initialize(path)
      @path = path
      @heaps = []
      @offset = 0
    end

    def parse
      read_each_line do |line|
        if line =~ /^chunk ([a-z0-9]+) size +([0-9]+) bytes (\(top\)|\(fence\) |\[free\]| ) *(.*)/
          process_chunk(line, $1, $2, $3, $4)
        elsif line =~ /^Heap  ([a-z0-9]+) size +([0-9]+) /i
          process_heap_start(line, $1, $2)
        elsif line =~ /^Pages in use for 0x([0-9a-f]+)-0x([0-9a-f]+): ([10\?]+)/
          process_pages_in_use(line, $1, $2, $3)
        end
      end

      sort_all!

      self
    end

  private
    def read_each_line
      File.open(@path, 'r:utf-8') do |f|
        while !f.eof?
          line = f.readline.strip
          yield(line)
        end
      end
    end

    def process_heap_start(line, addr, size)
      heap = Heap.new(@heaps.size, addr.to_i(16), size.to_i)
      @heaps << heap
    end

    def process_pages_in_use(line, start_addr, end_addr, usage)
      heap = @heaps.last
      start_addr = start_addr.to_i(16)
      end_addr = end_addr.to_i(16)

      addr = start_addr
      while addr < end_addr
        heap.page_dirtiness[addr] = 
          case usage[(addr - start_addr) / PAGE_SIZE]
          when '1'
            true
          when '0'
            false
          else
            nil
          end
        addr += PAGE_SIZE
      end
    end

    def process_chunk(line, addr, size, type, preview)
      heap = @heaps.last
      chunk = Chunk.new(
        heap,
        addr.to_i(16),
        heap.chunks.size,
        size.to_i,
        analyze_chunk_type(type),
        preview.empty? ? nil : preview)
      heap.chunks << chunk
    end

    def analyze_chunk_type(type)
      if type =~ /top/
        :top
      elsif type =~ /fence/
        :fence
      elsif type =~ /free/
        :free
      else
        :used
      end
    end

    def sort_all!
      @heaps.sort! do |a, b|
        a.addr <=> b.addr
      end
      @heaps.each do |heap|
        heap.chunks.sort! do |a, b|
          a.addr <=> b.addr
        end
      end
    end
  end

  # Heap a collection of Heap objects, splits their chunks
  # into pages and blocks of BLOCK_SIZE, for use in visualization.
  class ChunkSplitter
    attr_reader :heaps

    def initialize(heaps)
      @heaps = heaps
    end

    def perform
      @heaps.each do |heap|
        chunk = heap.chunks.first
        last_chunk = heap.chunks.last
        last_chunk_end_addr = last_chunk.addr + last_chunk.size
        addr = chunk.addr

        while addr < last_chunk_end_addr
          page_addr = addr & ~PAGE_SIZE_MASK
          page = Page.new(
            heap,
            page_addr,
            heap.page_dirtiness[page_addr]
          )
          heap.pages << page

          page_or_last_chunk_end_addr = [
            page.addr + PAGE_SIZE,
            last_chunk_end_addr
          ].min

          while addr < page_or_last_chunk_end_addr
            block = Block.new(
              page,
              chunk,
              addr,
              page.blocks.size,
              addr + BLOCK_SIZE >= chunk.addr + chunk.size
            )
            page.blocks << block

            addr += BLOCK_SIZE
            if block.end_of_chunk?
              chunk = heap.chunks[chunk.number + 1]
            end
          end
        end

        heap.page_dirtiness.clear
        heap.page_dirtiness = nil
      end

      self
    end
  end

  class HtmlVisualizer
    def initialize(heaps, dir)
      @heaps = heaps
      @dir = dir
    end

    def perform
      open_html_file do
        start_of_document
        save_clean_page_image
        @heaps.each_with_index do |heap, i|
          puts "Writing heap 0x#{heap.addr.to_s(16)} [#{i + 1}/#{@heaps.size}]"
          start_of_heap(heap)
          heap.pages.each do |page|
            start_of_page(page)
            write_page_image(page)
            end_of_page(page)
          end
          end_of_heap(heap)
        end
        end_of_document
      end

      self
    end

  private
    NUM_BLOCKS_1D = Math.sqrt(PAGE_SIZE / BLOCK_SIZE).to_i
    BLOCK_SCALE = 1
    PAGE_BG_COLOR = ChunkyPNG::Color.rgb(0x77, 0x77, 0x77)
    USED_BLOCK_COLORS = [
      ChunkyPNG::Color.rgb(0xff, 0, 0),
      ChunkyPNG::Color.rgb(0xf0, 0, 0),
      ChunkyPNG::Color.rgb(0xe1, 0, 0),
      ChunkyPNG::Color.rgb(0xd2, 0, 0),
    ]
    FREE_BLOCK_COLORS = [
      ChunkyPNG::Color.rgb(0xce, 0xce, 0xce),
      ChunkyPNG::Color.rgb(0xbf, 0xbf, 0xbf),
      ChunkyPNG::Color.rgb(0xb0, 0xb0, 0xb0),
      ChunkyPNG::Color.rgb(0xa1, 0xa1, 0xa1),
    ]
    CLEAN_PAGE_COLOR = ChunkyPNG::Color.rgb(0xff, 0xff, 0xff)
    CLEAN_PAGE_IMAGE = ChunkyPNG::Image.new(
      NUM_BLOCKS_1D * BLOCK_SCALE,
      NUM_BLOCKS_1D * BLOCK_SCALE,
      CLEAN_PAGE_COLOR)
    CLEAN_PAGE_IMAGE_BASE_NAME = 'page-clean.png'

    STYLESHEET = %Q{
      body {
        font-family: sans-serif;
      }

      heap {
        display: block;
        border: solid 1px black;
        margin-bottom: 2rem;
      }

      page-title {
        display: none;
      }

      heap-title,
      heap-content {
        display: block;
      }

      heap-title {
        padding: 1rem;
      }

      heap-title h2 {
        margin: 0;
      }

      heap-title .stats td,
      heap-title .stats th {
        text-align: right;
        padding-right: 1em;
      }

      page {
        display: inline-block;
        vertical-align: top;
        border: solid 1px #777;
      }
    }

    def open_html_file
      File.open("#{@dir}/index.html", 'w:utf-8') do |f|
        @io = f
        yield
      end
    end

    def save_clean_page_image
      CLEAN_PAGE_IMAGE.save(clean_page_image_path)
    end

    def clean_page_image_path
      @clean_page_image_path ||= "#{@dir}/#{CLEAN_PAGE_IMAGE_BASE_NAME}"
    end

    def start_of_document
      @io.printf %Q{<html>\n}
      @io.printf %Q{<head>\n}
      @io.printf %Q{\t<title>Heap visualizer</title>\n}
      @io.printf %Q{\t<link rel="stylesheet" href="stylesheet.css">\n}
      @io.printf %Q{</head>\n}
      @io.printf %Q{<body>\n}

      File.open("#{@dir}/stylesheet.css", 'w:utf-8') do |f|
        f.write(STYLESHEET)
      end
    end

    def start_of_heap(heap)
      maybe_dirty_pages = heap.maybe_dirty_pages
      clean_pages = heap.clean_pages

      @io.printf %Q{<heap>\n}
      @io.printf %Q{
          <heap-title>
            <h2>Heap %d &mdash; 0x%08x</h2>
            <table class="stats">
              <tr>
                <th>Virtual</th>
                <td>%.1f MB</td>
                <td>%d pages</td>
              </tr>
              <tr>
                <th>Dirty</th>
                <td>%.1f MB</td>
                <td>%d pages</td>
                <td>%d%%</td>
              </tr>
              <tr>
                <th>Clean</th>
                <td>%.1f MB</td>
                <td>%d pages</td>
                <td>%d%%</td>
              </tr>
            </table>
          </heap-title>
        }, heap.number, heap.addr,

          heap.size / 1024.0 / 1024, heap.pages.size,

          maybe_dirty_pages.size * PAGE_SIZE / 1024.0 / 1024,
          maybe_dirty_pages.size,
          maybe_dirty_pages.size * 100 / heap.pages.size,

          clean_pages.size * PAGE_SIZE / 1024.0 / 1024,
          clean_pages.size,
          clean_pages.size * 100 / heap.pages.size
      @io.printf %Q{\t<heap-content>}
    end

    def start_of_page(page)
      @io.printf %Q{<page>}
      @io.printf %Q{<page-title>%08x-%08x</page-title>},
        page.addr, page.addr + page.size
    end

    def write_page_image(page)
      title = "0x#{page.addr.to_s(16)}"
      if page.maybe_dirty?
        image = ChunkyPNG::Image.new(
          NUM_BLOCKS_1D * BLOCK_SCALE,
          NUM_BLOCKS_1D * BLOCK_SCALE,
          PAGE_BG_COLOR)
        page.blocks.each_with_index do |block, block_index|
          x = (block_index % NUM_BLOCKS_1D) * BLOCK_SCALE
          y = (block_index / NUM_BLOCKS_1D) * BLOCK_SCALE
          color = color_for_block(block)
          BLOCK_SCALE.times do |scale_x_index|
            BLOCK_SCALE.times do |scale_y_index|
              image[x + scale_x_index, y + scale_y_index] = color
            end
          end
        end

        path, basename = path_for_page_image(page)
        image.save(path)
        @io.printf %Q{<img src="#{basename}" class="page-content" title="#{ERB::Util.h title}">}
      else
        @io.printf %Q{<img src="#{CLEAN_PAGE_IMAGE_BASE_NAME}" class="page-content" title="#{ERB::Util.h title}">}
      end
    end

    def color_for_block(block)
      if block.used?
        USED_BLOCK_COLORS[block.chunk.number % USED_BLOCK_COLORS.size]
      else
        FREE_BLOCK_COLORS[block.chunk.number % USED_BLOCK_COLORS.size]
      end
    end

    def path_for_page_image(page)
      basename = "page-#{page.addr.to_s(16)}.png"
      ["#{@dir}/#{basename}", basename]
    end

    def end_of_page(page)
      @io.printf %Q{</page>}
    end

    def end_of_heap(heap)
      @io.printf %Q{</heap-content>\n}
      @io.printf %Q{</heap>\n}
    end

    def end_of_document
      @io.printf %Q{</body>\n}
      @io.printf %Q{</html>\n}
    end
  end
end

if ARGV.size != 2
  abort "Usage: ./visualize_heap.rb <LOGFILE> <OUTPUT DIR>"
end

puts "Parsing file"
parser = HeapVisualizer::HeapChunksLogParser.new(ARGV[0]).parse
puts "Splitting heap chunks"
splitter = HeapVisualizer::ChunkSplitter.new(parser.heaps).perform
heaps = splitter.heaps

puts "Garbage collecting"
GC.start

puts "Writing output"
HeapVisualizer::HtmlVisualizer.new(heaps, ARGV[1]).perform
