require 'uri'
require 'cgi'
require 'digest/sha1'
require 'rubygems'
require 'sinatra'
require 'image_science'
require 'aws/s3'
require 'memcache'
require 'json'

#
# cache
#
class Cache
  @@bucket = 'pinkyurl'
  attr_reader :memcache

  def initialize
    config = YAML.load_file 'config/aws.yml'
    AWS::S3::Base.establish_connection! config

    config = YAML.load_file 'config/memcache.yml' rescue nil
    @memcache = MemCache.new config[:servers] || 'localhost:11211'
  end

  def expire file, host
    k = key file
    @memcache.delete k
    AWS::S3::S3Object.delete k, bucket(host)
  rescue Exception => e
    warn e
  end

  def put file, host
    Thread.new { _put file, host }
  end

  def _put file, host, content_type = 'image/png'
    k = key file
    AWS::S3::Bucket.create bucket(host)
    AWS::S3::S3Object.store k, open(file), bucket(host),
      :content_type => content_type, :access => :public_read
    obj = AWS::S3::S3Object.find k, bucket(host)  # TODO: skip this extra find?
    returning 'https://s3.amazonaws.com' + obj.path do |r|
      @memcache.set k, r
    end
  end

  def get file, host
    k = key file
    r = @memcache.get k
    unless r
      obj = AWS::S3::S3Object.find k, bucket(host)
      @memcache.set k, r = 'https://s3.amazonaws.com' + obj.path
    end
    r
  rescue Exception => e
    warn e
    nil
  end

  def key file
    Digest::SHA1.hexdigest file
  end

  private
    def bucket host
      @@bucket + '-' + host
    end
end

class DisabledCache < Cache
  class DisabledMemCache
    def get k; end
    def set k, v; end
  end
  def initialize; @memcache = DisabledMemCache.new end
  def expire file, host; end
  def _put file, host, content_type = 'image/png'; file end
  def get file, host; end
end

configure do
  @@cache = DisabledCache.new
end

configure :production do
  @@cache = Cache.new
end

#
# helpers
#
def cutycapt url, file
  url = CGI.unescape url  # qt expects no %-escaping
                          # http://doc.trolltech.com/4.5/qurl.html#QUrl
  cmd = "CutyCapt --delay=1000 --out-format=png --url='#{url}' --out='#{file}'"
  if ENV['DISPLAY']
    `#{cmd}`
  else
    `xvfb-run -a --server-args="-screen 0, 800x600x24" #{cmd}`
  end
end

def cutycapt_with_cache url, file, force=nil
  if force || !File.exists?(file)
    FileUtils.mkdir_p File.dirname(file)
    key = @@cache.key "cutycapt-#{file}"
    if !force && cached = @@cache.memcache.get(key)
      File.open file, 'w' do |f| f.write cached end
    else
      cutycapt url, file
      @@cache.memcache.set key, File.read(file)
    end
  end
end

def crop input, output, size
  width, height = size.split 'x'
  ImageScience.with_image input do |img|
    w, h = img.width, img.height
    l, t, r, b = 0, 0, w, h

    if height
      b = (w.to_f / width.to_f * height.to_f).to_i
      b = h  if b > h
    else
      height = width.to_f / w * h
    end

    img.with_crop l, t, r, b do |cropped|
      cropped.resize width.to_i, height.to_i do |thumb|
        thumb.save output
      end
    end
  end
end

#
# routes/actions
#
get '/' do
  require 'haml'
  haml :index
end

get '/stylesheet.css' do
  require 'sass'
  sass :stylesheet
end

get '/i' do
  url = params[:url]
  sha1_url = Digest::SHA1.hexdigest url
  host = (URI.parse(url).host rescue nil)
  halt 'invalid url'  unless host && host != 'localhost'

  crop = params[:crop]; crop = nil  if crop.nil? || crop == ''
  file = "public/cache/#{crop || 'uncropped'}/#{sha1_url}"

  if params[:expire]
    @@cache.expire file, host
  elsif cached = @@cache.get(file, host)
    halt redirect(cached)
  end

  uncropped = "public/cache/uncropped/#{sha1_url}"
  cutycapt_with_cache url, uncropped, params[:expire]

  if crop && (!File.exists?(file) || params[:expire])
    FileUtils.mkdir_p File.dirname(file)
    crop uncropped, file, crop
  end

  @@cache.put file, host
  send_file file, :type => 'image/png'
end

post '/i' do
  uploaded = params[:file]
  # TODO: using tempfile.path isn't secure enough
  file, host = uploaded[:tempfile].path, 'POST'
  headers['Location'] = @@cache._put file, host, uploaded[:type]

  status 201
  ImageScience.with_image file do |img|
    {"size" => {"width" => img.width, "height" => img.height}}.to_json
  end rescue "{}"
end

#
# views
#
__END__
@@stylesheet
body, input
  :font-size 32pt
  .minor, .minor input
    :font-size 12pt
input[type=submit]
  :border solid 1px gray
  :-webkit-border-radius 5px
  :-moz-border-radius 5px

form
  :text-align center
  :margin-top 3em
  input#url
    :width 20ex
  input#crop
    :width 5ex

@@ index
%html
  %head
    %title= 'pinkyurl'
    %link{:rel => 'stylesheet', :type => 'text/css', :media => 'all', :href => '/stylesheet.css'}
  %body
    %form{:action => '/i', :method => 'get'}
      %p
        %label{:for => 'url'}= 'url'
        %input{:name => 'url', :id => 'url', :value => 'http://www.google.com'}
        %input{:type => 'submit', :value => 'Go'}
      %p.minor
        %label{:for => 'crop'}= 'crop'
        %input{:name => 'crop', :id => 'crop'}
        %input{:name => 'expire', :id => 'expire', :type => 'checkbox', :value => 1}
        %label{:for => 'expire'}= 'expire'
    %form{:action => '/i', :method => 'post', :enctype => 'multipart/form-data' }
      %p
        %label{:for => 'file'}= 'file'
        %input{:name => 'file', :id => 'file', :type => 'file'}
        %input{:type => 'submit', :value => 'Upload'}