require "mysql2"

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

# Call it like this:
#   RAILS_ENV=production bundle exec ruby script/import_scripts/xenforo.rb
class ImportScripts::XenForo < ImportScripts::Base

  XENFORO_DB = "xenforo_db"
  TABLE_PREFIX = "xf_"
  BATCH_SIZE = 1000
  #FORUM URL WITH HTTP://
  FORUM_URL = ""

  def initialize
    super

    @client = Mysql2::Client.new(
      host: "localhost",
      username: "root",
      password: "",
      database: XENFORO_DB
    )
  end

  def execute
    import_users
    import_categories
    import_posts
  end

  def import_users
    puts '', "creating users"

    total_count = mysql_query("SELECT count(*) count FROM #{TABLE_PREFIX}user;").first['count']

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(
        "SELECT u.user_id id, u.username username, u.email email, u.custom_title title, u.register_date created_at,
                u.last_activity last_visit_time, u.user_group_id, u.avatar_date, ua.data password
				FROM #{TABLE_PREFIX}user u, #{TABLE_PREFIX}user_authenticate ua
				WHERE u.user_id = ua.user_id
         LIMIT #{BATCH_SIZE}
         OFFSET #{offset};")

      break if results.size < 1

      next if all_records_exist? :users, results.map {|u| u["id"].to_i}

      create_users(results, total: total_count, offset: offset) do |user|
        next if user['username'].blank? || user['email'].start_with?('@')
        { id: user['id'],
          email: user['email'],
          username: user['username'],
		  password: user['password'],
          title: user['title'],
          created_at: Time.zone.at(user['created_at']),
          last_seen_at: Time.zone.at(user['last_visit_time']),
          moderator: false,
          admin: false,
		  post_create_action: proc do |client|
		    if client.uploaded_avatar_id.blank? && user['avatar_date'] != 0
			  puts user['id'].to_s
              path = avatar_fullpath(user['id'], user['avatar_date']) and begin
			    upload = create_upload(client.id, path, user['id'])
			    if upload.persisted?
                  client.create_user_avatar
                  client.user_avatar.update(custom_upload_id: upload.id)
                  client.update(uploaded_avatar_id: upload.id)
                  client.refresh_avatar
                else
                  puts "Upload failed!"
                end
              rescue SystemCallError => err
                puts "Could not import avatar: #{err.message}"
              end
			end
		  end
		}
      end
    end
  end
  
  def import_categories
    puts "", "importing categories..."

    # Note that this script uses Prefix as Category, you may want to change this as per your requirement
    categories = mysql_query("
                              SELECT node_id id, title
                              FROM #{TABLE_PREFIX}node
                              ORDER BY node_id ASC
                            ").to_a

    create_categories(categories) do |category|
      {
        id: category["id"],
        name: category["title"]
      }
    end
  end

  def import_posts
    puts "", "creating topics and posts"

    total_count = mysql_query("SELECT count(*) count from #{TABLE_PREFIX}post").first["count"]

    batches(BATCH_SIZE) do |offset|
      results = mysql_query("
        SELECT p.post_id id,
               t.thread_id topic_id,
               t.node_id category_id,
               t.title title,
               t.first_post_id first_post_id,
               p.user_id user_id,
               p.message raw,
               p.post_date created_at
        FROM #{TABLE_PREFIX}post p,
             #{TABLE_PREFIX}thread t
        WHERE p.thread_id = t.thread_id
        ORDER BY p.post_date
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ").to_a

      break if results.size < 1
      next if all_records_exist? :posts, results.map {|p| p['id'] }

      create_posts(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        mapped[:id] = m['id']
        mapped[:user_id] = user_id_from_imported_user_id(m['user_id']) || -1
        mapped[:raw] = process_xenforo_post(m['raw'], m['id'])
        mapped[:created_at] = Time.zone.at(m['created_at'])

        if m['id'] == m['first_post_id']
          if m['category_id'].to_i == 0 || m['category_id'].nil?
            mapped[:category] = SiteSetting.uncategorized_category_id
          else
            mapped[:category] = category_id_from_imported_category_id(m['category_id'].to_i)
          end
          mapped[:title] = CGI.unescapeHTML(m['title'])
        else
          parent = topic_lookup_from_imported_post_id(m['first_post_id'])
          if parent
            mapped[:topic_id] = parent[:topic_id]
          else
            puts "Parent post #{m['first_post_id']} doesn't exist. Skipping #{m["id"]}: #{m["title"][0..40]}"
            skip = true
          end
        end

        skip ? nil : mapped
      end
    end

  end

  def process_xenforo_post(raw, import_id)
    s = raw.dup

    # :) is encoded as <!-- s:) --><img src="{SMILIES_PATH}/icon_e_smile.gif" alt=":)" title="Smile" /><!-- s:) -->
    s.gsub!(/<!-- s(\S+) --><img (?:[^>]+) \/><!-- s(?:\S+) -->/, '\1')

    # Some links look like this: <!-- m --><a class="postlink" href="http://www.onegameamonth.com">http://www.onegameamonth.com</a><!-- m -->
    s.gsub!(/<!-- \w --><a(?:.+)href="(\S+)"(?:.*)>(.+)<\/a><!-- \w -->/, '[\2](\1)')

    # Many phpbb bbcode tags have a hash attached to them. Examples:
    #   [url=https&#58;//google&#46;com:1qh1i7ky]click here[/url:1qh1i7ky]
    #   [quote=&quot;cybereality&quot;:b0wtlzex]Some text.[/quote:b0wtlzex]
    s.gsub!(/:(?:\w{8})\]/, ']')

    # Remove mybb video tags.
    s.gsub!(/(^\[video=.*?\])|(\[\/video\]$)/, '')

    s = CGI.unescapeHTML(s)

    # phpBB shortens link text like this, which breaks our markdown processing:
    #   [http://answers.yahoo.com/question/index ... 223AAkkPli](http://answers.yahoo.com/question/index?qid=20070920134223AAkkPli)
    #
    # Work around it for now:
    s.gsub!(/\[http(s)?:\/\/(www\.)?/, '[')

    # [QUOTE]...[/QUOTE]
    s.gsub!(/\[quote\](.+?)\[\/quote\]/im) { "\n> #{$1}\n" }
    
    # [QUOTE]...[/QUOTE]
    s.gsub!(/\[quote\](.+?)\[\/quote\]/im) { "\n> #{$1}\n" }

    # [URL=...]...[/URL]
    s.gsub!(/\[url="?(.+?)"?\](.+)\[\/url\]/i) { "[#{$2}](#{$1})" }

    # [IMG]...[/IMG]
    s.gsub!(/\[\/?img\]/i, "")

    # convert list tags to ul and list=1 tags to ol
    # (basically, we're only missing list=a here...)
    s.gsub!(/\[list\](.*?)\[\/list:u\]/m, '[ul]\1[/ul]')
    s.gsub!(/\[list=1\](.*?)\[\/list:o\]/m, '[ol]\1[/ol]')
    # convert *-tags to li-tags so bbcode-to-md can do its magic on phpBB's lists:
    s.gsub!(/\[\*\](.*?)\[\/\*:m\]/, '[li]\1[/li]')

    # [YOUTUBE]<id>[/YOUTUBE]
    s.gsub!(/\[youtube\](.+?)\[\/youtube\]/i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }

    # [youtube=425,350]id[/youtube]
    s.gsub!(/\[youtube="?(.+?)"?\](.+)\[\/youtube\]/i) { "\nhttps://www.youtube.com/watch?v=#{$2}\n" }

    # [MEDIA=youtube]id[/MEDIA]
    s.gsub!(/\[MEDIA=youtube\](.+?)\[\/MEDIA\]/i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }

    # [ame="youtube_link"]title[/ame]
    s.gsub!(/\[ame="?(.+?)"?\](.+)\[\/ame\]/i) { "\n#{$1}\n" }

    # [VIDEO=youtube;<id>]...[/VIDEO]
    s.gsub!(/\[video=youtube;([^\]]+)\].*?\[\/video\]/i) { "\nhttps://www.youtube.com/watch?v=#{$1}\n" }

    # [USER=706]@username[/USER]
    s.gsub!(/\[user="?(.+?)"?\](.+)\[\/user\]/i) { $2 }

    # Remove the color tag
    s.gsub!(/\[color=[#a-z0-9]+\]/i, "")
    s.gsub!(/\[\/color\]/i, "")
	
  	# [FONT=font]text[/FONT]
  	s.gsub!(/\[font=(.+?)\](.+?)\[\/font\]/i) { $2 }
	
  	# [FONT=font]\ntext[/FONT]
  	s.gsub!(/\[font=(.+?)\]\r?\n(.+?)\[\/font\]/i) { $2 }
  	
  	# [FONT=text]
  	s.gsub!(/\[font=(.+?)\]/i) { $2 }
  	
  	# [/FONT]
  	s.gsub!(/\[\/font\]/i) { $2 }
  	
  	# [LIST]
  	s.gsub!(/\[list\]/i) { "" }
  	
  	# [LIST=1]
  	s.gsub!(/\[list=(.+?)\]/i) { "" }
  	
  	# [/LIST]
  	s.gsub!(/\[\/list\]/i) { "" }
  	
  	# [*]
  	s.gsub!(/\[\*\]/i) { " * " }
  	
  	# [h2]text[/h2]
  	s.gsub!(/\[h2\](.+?)\[\/h2\]/i) { "\n# #{$1}\n" }
  	
  	# [SPOILER]text[/SPOILER]
  	s.gsub!(/\[spoiler\](.+?)\[\/spoiler\]/i) { "[details=Spoiler]#{$1}[/details]" }
  	
  	# [SPOILER=""]text[/SPOILER]
  	s.gsub!(/\[spoiler=(.+?)\](.+?)\[\/spoiler\]/i) { "[details=#{$1}]#{$2}[/details]" }
  	
  	# [CENTER]text[/CENTER]
  	s.gsub!(/\[center\](.+?)\[\/center\]/i) { "<div align=center>#{$1}</div>" }
  	
  	# [LEFT]text[/LEFT]
  	s.gsub!(/\[left\](.+?)\[\/left\]/i) { "<div align=left>#{$1}</div>" }
  	
  	# [RIGHT]text[/RIGHT]
  	s.gsub!(/\[right\](.+?)\[\/right\]/i) { "<div align=right>#{$1}</div>" }
  	
  	# [B]text[/B]
  	s.gsub!(/\[b\](.+?)\[\/b\]/i) { "**#{$1}**" }
  
  	# [SIZE=""]text[/SIZE]
  	size = s.match(/\[size="?(.+?)"?\](.+)\[\/size\]/i)[1] unless s.match(/\[size="?(.+?)"?\](.+)\[\/size\]/i).nil?
  	if size != nil
  	  if size.to_i <= 2
  	    s.gsub!(/\[size="?(.+?)"?\](.+)\[\/size\]/i) { "<small>#{$2}</small>" }
  	  elsif size.to_i <= 5
  		s.gsub!(/\[size="?(.+?)"?\](.+)\[\/size\]/i) { "<medium>#{$2}</medium>" }
  	  elsif size.to_i <= 7
  	    s.gsub!(/\[size="?(.+?)"?\](.+)\[\/size\]/i) { "<big>#{$2}</big>" }
  	  end
  	end
    s
  end

  def mysql_query(sql)
    @client.query(sql, cache_rows: false)
  end
  
  def avatar_fullpath(filename, filedate)
    begin
      group = filename / 1000
      hotlinked = FileHelper.download(FORUM_URL + '/data/avatars/l/' + group.to_i.to_s + '/' + filename.to_s + '.jpg?' + filedate.to_s, max_file_size: SiteSetting.max_image_size_kb.kilobytes, tmp_file_name: "discourse-hotlinked", follow_redirect: true)
    rescue StandardError => err
        puts "Error downloading avatar: #{err.message}. Skipping..."
    end
    if hotlinked
      if hotlinked.size <= SiteSetting.max_image_size_kb.kilobytes
        return hotlinked
      else
        Rails.logger.error("Failed to pull hotlinked image: #{filename} - Image is bigger than #{@max_size}")
          nil
      end
    else
      Rails.logger.error("There was an error while downloading '#{filename}' locally.")
      nil
    end
  end
end

ImportScripts::XenForo.new.perform
