require 'cgi'
require 'digest/sha1'
require 'rubygems'
require 'sinatra'
require 'image_science'
require 'aws/s3'

class Cache
  def initialize
    config = YAML.load_file 'aws.yml'  rescue {}
    AWS::S3::Base.establish_connection! config
    AWS::S3::Bucket.create 'pinkyurl'
  end

  def put file
    key = Digest::SHA1.hexdigest file
    AWS::S3::S3Object.store key, open(file), 'pinkyurl',
      :content_type => 'image/png', :access => :public_read
  end

  def get file
    key = Digest::SHA1.hexdigest file
    obj = AWS::S3::S3Object.find key, 'pinkyurl'
    "https://s3.amazonaws.com" + obj.path
  rescue Exception => e
    nil
  end
end

def cutycapt url, file
  `xvfb-run -a --server-args="-screen 0, 800x600x24" CutyCapt --delay=1000 --out-format=png --url=#{url} --out=#{file}`
end

def crop file, size
  ImageScience.with_image file do |img|
    w, h = img.width, img.height
    l, t, r, b = 0, 0, w, h

    t, b = 0, w if h > w

    img.with_crop l, t, r, b do |cropped|
      cropped.thumbnail size do |thumb|
        thumb.save file
      end
    end
  end
end

configure do
  @@cache = Cache.new
end

get '/' do
  url = CGI.escape 'http://www.google.com'
  href = 'i?url=' + url + '&crop=200'
  "go to <a href=\"#{href}\">#{href}</a>"
end

get '/i' do
  url = params[:url]
  file = "public/cache/#{params[:crop]}/#{CGI.escape url}"

  if cached = @@cache.get(file)
    redirect cached
    return
  end

  unless File.exists?(file)
    FileUtils.mkdir_p File.dirname(file)
    cutycapt url, file
    crop file, params[:crop] if params[:crop]
  end

  @@cache.put file
  send_file file, :type => 'image/png'
end
