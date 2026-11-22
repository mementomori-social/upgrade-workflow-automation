# frozen_string_literal: true

# Fills every view of a local dev instance with test content:
#   cd /opt/mastodon && RAILS_ENV=development bin/rails runner ~/upgrade-workflow-automation/mastodon-seed-test-content.rb
# SEED_VIEWERS=alice,bob picks who gets filled, default is whoever recently used the instance.

LOCAL_DOMAIN_RE = /(\.test|\.localhost|\.local|\Alocalhost)(:\d+)?\z/
LOCAL_DB_HOSTS  = ['', 'localhost', '127.0.0.1', '::1'].freeze

abort 'Refusing: not the development environment' unless Rails.env.development?
abort 'Refusing: LOCAL_DOMAIN is not a local one' unless Rails.configuration.x.local_domain.match?(LOCAL_DOMAIN_RE)

db_host = ActiveRecord::Base.connection_db_config.configuration_hash[:host].to_s
abort 'Refusing: the database is not on this machine' unless LOCAL_DB_HOSTS.include?(db_host) || db_host.start_with?('/')
abort 'Refusing: media would go to remote storage' if ENV['S3_ENABLED'] == 'true' || ENV['SWIFT_ENABLED'] == 'true'

# A dev database can hold real inboxes, push subscriptions and relays.
# Every job and request of this process is dropped, so nothing seeded can reach them.
require 'sidekiq/testing'
Sidekiq::Testing.fake!
SidekiqUniqueJobs.configure { |config| config.enabled = false }
ActionMailer::Base.perform_deliveries = false

module OutgoingRequestBlock
  def perform(...)
    raise 'The seeder does not make outgoing requests'
  end
end

Request.prepend(OutgoingRequestBlock)
Chewy.root_strategy = :bypass
Chewy.strategy(:bypass)
Rails.logger.level = :warn
ActiveRecord::Base.logger = nil

class TestContentSeeder
  include Redisable

  PEOPLE = [
    'Ada', 'Bo', 'Casimir', 'Dee', 'Elowen', 'Fitz', 'Greta', 'Hiro', 'Ines', 'Jun',
    'Kestrel', 'Lumi', 'Marisol', 'Nico', 'Odalys', 'Pim', 'Quill', 'Rafi', 'Sunniva', 'Tove',
    'Ulla', 'Vesper', 'Wren', 'Xavi', 'Yara', 'Zeno', 'Bartholomew Longname Featherstonehaugh',
    'Mo', 'Aurelio', 'Saga'
  ].freeze

  FOLLOWED_COUNT  = 18
  FAN_COUNT       = 12
  REQUESTER_COUNT = 3
  ACTIVE_WITHIN   = 30.days
  MAX_VIEWERS     = 5

  # A rerun within this reuses the posts, later runs add a fresh batch
  BATCH_LIFETIME = 6.hours
  POSTS_EACH     = 3
  POST_SPACING   = 2.minutes

  # Trends refresh every 5 minutes and drop what has too little engagement
  TREND_FAVOURITES = 2_000..9_000
  TREND_BOOSTS     = 300..1_500
  TREND_USES       = 100

  LIST_TITLE = 'Test content'
  TAGS = %w(photography coffee cycling linux gardening books cooking design astronomy music film cats).freeze

  TEXTS = [
    'Morning light on the lake. Worth getting up for.',
    'Short one.',
    "Things I learned this week:\n\n1. Read the error message\n2. Read it again\n3. It was a typo",
    'Does anybody have a favourite small tool they use every day and never talk about?',
    'A long post to test wrapping and collapsing. ' * 10,
    'averyveryverylongwordwithoutanyspacestoseehowthelayoutwrapsitonnarrowscreens is the word of the day',
    'Emoji test 🚲 ☕ 🌲 🐈 in the middle of a sentence.',
    'A link in text https://example.com/a/rather/long/path/to/see/how/links/are/shortened',
  ].freeze

  # Throwaway test content, the same samples as demo_feed:languages
  TRANSLATED_TEXTS = {
    'fi' => 'Testiviesti suomeksi, kielisuodattimen testausta varten.',
    'ja' => '日本語のテスト投稿です。言語フィルターの確認用。',
    'de' => 'Testbeitrag auf Deutsch, um den Sprachfilter zu prüfen.',
    'sv' => 'Testinlägg på svenska för att kontrollera språkfiltret.',
  }.freeze

  IMAGE_SIZES  = [[1200, 800], [800, 1200], [1000, 1000], [1600, 600]].freeze
  AVATAR_SIZE  = [400, 400].freeze
  HEADER_SIZE  = [1500, 500].freeze
  CARD_SIZE    = [1200, 630].freeze
  RGB_CEILING  = 220
  ARTICLE_COUNT = 10

  def run
    @people  = seed_people
    @viewers = find_viewers
    abort 'Nobody to fill: log in once or pass SEED_VIEWERS=username' if @viewers.empty?

    @posts = recent_posts.presence || create_batch
    seed_trends
    seed_profiles
    @viewers.each { |viewer| fill_viewer(viewer) }
    refresh_suggestions

    puts "Test content ready for #{@viewers.map { |viewer| "@#{viewer.username}" }.join(', ')}"
  end

  private

  def find_viewers
    names = ENV.fetch('SEED_VIEWERS', '').split(',').map { |name| name.strip.delete_prefix('@') }.compact_blank

    if names.any?
      return names.map { |name| Account.find_local(name) || abort("No local account @#{name}") }
    end

    user_ids = SessionActivation.where(updated_at: ACTIVE_WITHIN.ago..)
      .where.not(user_id: User.where(account_id: @people.map(&:id)).select(:id))
      .group(:user_id).order(Arel.sql('MAX(updated_at) DESC')).limit(MAX_VIEWERS).pluck(:user_id)

    User.where(id: user_ids).includes(:account).map(&:account)
  end

  def seed_people
    PEOPLE.each_with_index.map do |name, index|
      username = format('seed_%02d', index + 1)
      Account.find_local(username) || create_person(username, name, index)
    end
  end

  def create_person(username, name, index)
    account = Account.new(
      username: username,
      display_name: name.truncate(Account::DISPLAY_NAME_LENGTH_LIMIT),
      note: "Test account. Posts about ##{TAGS[index % TAGS.size]} and whatever else needs testing.",
      discoverable: true,
      indexable: true,
      trendable: true
    )

    with_image(AVATAR_SIZE, index) { |file| account.avatar = file }
    with_image(HEADER_SIZE, index + 1) { |file| account.header = file }
    account.save!

    # Without an approved user an account stays out of suggestions, the directory and link timelines
    create_user(account)
    account
  end

  def create_user(account)
    user = User.new(
      account: account,
      email: "#{account.username}@example.com",
      password: SecureRandom.hex,
      agreement: true,
      approved: true,
      confirmed_at: Time.now.utc,
      bypass_registration_checks: true
    )
    user.save!(validate: false)
    user.update_column(:approved, true)
  end

  def with_image(size, index)
    random = Random.new(index)
    colour = Array.new(3) { random.rand(RGB_CEILING) }
    shade  = Vips::Image.xyz(*size)[0] / size.first

    Tempfile.create(['seed', '.png']) do |file|
      ((shade * (255 - colour.max)) + colour).cast(:uchar).copy(interpretation: :srgb).write_to_file(file.path)
      yield File.open(file.path)
    end
  end

  def recent_posts
    since = Mastodon::Snowflake.id_at(BATCH_LIFETIME.ago, with_random: false)
    posts = Status.where(account_id: @people.map(&:id), id: since.., reblog_of_id: nil, in_reply_to_id: nil, visibility: :public)
      .where.missing(:quote, :mentions)
      .reorder(id: :asc)
      .to_a

    # An interrupted run leaves a partial batch, which is not reused
    posts if posts.size >= PEOPLE.size * POSTS_EACH
  end

  def create_batch
    puts 'Creating posts...'
    total = PEOPLE.size * POSTS_EACH

    posts = Array.new(total) do |index|
      create_post(@people[index % @people.size], index, (total - index) * POST_SPACING)
    end

    posts.first(FAN_COUNT).each_with_index { |post, index| add_engagement(post, index) }
    posts.map(&:reload)
  end

  def create_post(author, index, age)
    language = index % 7 == 3 ? TRANSLATED_TEXTS.keys[index % TRANSLATED_TEXTS.size] : 'en'
    text     = TRANSLATED_TEXTS[language] || TEXTS[index % TEXTS.size]
    warning  = index % 17 == 5
    text     = "#{text}\n\n##{TAGS[(index / 2) % TAGS.size]}" if index.even?

    status = write_status(
      author,
      text,
      language: language,
      spoiler_text: warning ? 'Content warning test' : '',
      sensitive: warning,
      created_at: age.ago
    )

    attach_images(status, index) if (index + (3 * (index / PEOPLE.size))) % 4 == 1
    attach_poll(status) if index % 13 == 6
    status
  end

  def write_status(author, text, **options)
    status = author.statuses.create!({ text: text, visibility: :public, language: 'en' }.merge(options))
    ProcessHashtagsService.new.call(status)
    status
  end

  def attach_images(status, index)
    media_ids = Array.new((index % IMAGE_SIZES.size) + 1) do |number|
      with_image(IMAGE_SIZES[(index + number) % IMAGE_SIZES.size], index + number) do |file|
        MediaAttachment.create!(account: status.account, status: status, file: file, description: 'Coloured test gradient').id
      end
    end

    status.update_columns(ordered_media_attachment_ids: media_ids)
  end

  def attach_poll(status)
    poll = Poll.create!(account: status.account, status: status, options: %w(Yes No Maybe), expires_at: 1.day.from_now)
    status.update_columns(poll_id: poll.id)
    @people.first(FAN_COUNT).without(status.account).each_with_index do |voter, index|
      PollVote.create!(account: voter, poll: poll.reload, choice: index % poll.options.size)
    end
  end

  def add_engagement(post, index)
    others = @people.without(post.account).rotate(index)
    others.first(FAN_COUNT).each { |person| favourite(person, post) }
    others.last(3).each { |person| boost(person, post) }
    others.first(3).each { |person| write_status(person, 'A reply to fill out the thread.', thread: post) }
    quote(others.last, post) if index < 3
  end

  def favourite(account, post)
    Favourite.find_or_create_by!(account: account, status: post)
  end

  def boost(account, post)
    account.statuses.find_by(reblog_of_id: post.id) || account.statuses.create!(reblog: post, visibility: :public)
  end

  def quote(account, post)
    Quote.find_by(account: account, quoted_status: post) || begin
      status = write_status(account, 'Quoting this one.')
      Quote.create!(status: status, quoted_status: post, state: :accepted)
    end
  end

  def seed_trends
    puts 'Filling Explore...'

    @posts.each_with_index { |post, index| make_trending(post, index) }
    seed_articles

    Tag.where(name: TAGS).find_each do |tag|
      tag.update_columns(max_score: nil, max_score_at: nil, trendable: true)
      TREND_USES.times { |number| Trends.tags.add(tag, number) }
    end

    Trends.refresh!
  end

  def make_trending(post, index)
    random = Random.new(index)
    stat   = StatusStat.find_or_initialize_by(status_id: post.id)
    stat.update!(favourites_count: random.rand(TREND_FAVOURITES), reblogs_count: random.rand(TREND_BOOSTS))

    Trends.statuses.register(post)
  end

  def seed_articles
    text_posts = @posts.reject(&:with_media?)

    ARTICLE_COUNT.times do |index|
      url  = "https://example.com/test-content/article-#{index + 1}"
      card = PreviewCard.find_by(url: url) || create_article(url, index)

      card.update_columns(max_score: nil, max_score_at: nil)
      [index, index + ARTICLE_COUNT].each { |position| link_article(card, text_posts[position]) }
      TREND_USES.times { |number| Trends.links.add(card, number) }
    end
  end

  def create_article(url, index)
    card = PreviewCard.new(
      url: url,
      title: "Test article #{index + 1}: #{TAGS[index]} in everyday life",
      description: 'A made-up article for testing link previews and trending news.',
      type: :link,
      link_type: :article,
      provider_name: 'Example News',
      author_name: PEOPLE[index],
      language: 'en',
      trendable: true
    )

    with_image(CARD_SIZE, index) { |file| card.image = file }
    card.save!
    card
  end

  def link_article(card, post)
    return if post.nil? || PreviewCardsStatus.exists?(status_id: post.id)

    PreviewCardsStatus.create!(preview_card: card, status: post, url: card.url)
    Rails.cache.delete("v3:statuses/#{post.id}")
  end

  def seed_profiles
    @people.first(FAN_COUNT).each_with_index do |person, index|
      post = @posts.find { |status| status.account_id == person.id }
      StatusPin.find_or_create_by!(account: person, status: post) if post && !StatusPin.exists?(account: person)

      name = TAGS[index]
      person.featured_tags.create!(name: name) unless person.featured_tags.joins(:tag).exists?(tags: { name: name })
    end
  end

  def fill_viewer(viewer)
    puts "Filling views of @#{viewer.username}..."

    followed  = @people.first(FOLLOWED_COUNT)
    strangers = @people.drop(FOLLOWED_COUNT)

    # Feeds are only built for people who signed in within the last week
    viewer.user.update_columns(current_sign_in_at: Time.now.utc) unless viewer.user.signed_in_recently?
    followed.each { |person| follow(viewer, person) }
    fill_notifications(viewer, followed, strangers)
    fill_conversations(viewer, followed.first(5))
    fill_saved(viewer, followed)
    fill_feeds(viewer, followed)
    fill_for_you(viewer)
    Rails.cache.delete("follow_recommendations/#{viewer.id}")
  end

  def follow(account, target)
    Follow.find_or_create_by!(account: account, target_account: target)
  end

  def fill_notifications(viewer, followed, strangers)
    targets = own_posts(viewer)

    @people.first(FAN_COUNT).each { |person| notify(viewer, follow(person, viewer), :follow) }

    targets.each_with_index do |post, index|
      fans = @people.rotate(index * 3)
      fans.first(FAN_COUNT - index).each { |person| notify(viewer, favourite(person, post), :favourite) }
      fans.last(5 - index).each { |person| notify(viewer, boost(person, post), :reblog) }
    end

    notify_mentions(viewer, followed, targets.first)
    notify_post_events(viewer, followed, targets.first)
    notify_collection(viewer)
    request_follows(viewer, strangers.first(REQUESTER_COUNT))
    request_notification(viewer, strangers.last)
  end

  def own_posts(viewer)
    posts = viewer.statuses
      .where(reblog_of_id: nil, in_reply_to_id: nil, visibility: :public)
      .where(id: ..Mastodon::Snowflake.id_at(Time.now.utc))
      .reorder(id: :desc).limit(3).to_a

    posts.presence || [write_status(viewer, 'My test post.')]
  end

  def notify(viewer, activity, type, filtered: false)
    key = { account: viewer, activity_id: activity.id, activity_type: activity.class.base_class.name, type: type }
    return if Notification.exists?(key)

    notification = Notification.new(account: viewer, activity: activity, type: type, filtered: filtered)
    notification.set_group_key!
    notification.save!
  end

  def notify_mentions(viewer, followed, own_post)
    followed.first(6).each_with_index do |person, index|
      next if mentioned_recently?(viewer, person)

      thread = own_post if index.even?
      text   = index.even? ? 'nice one, where was this?' : 'have you seen this?'
      status = write_status(person, "@#{viewer.username} #{text}", thread: thread)
      notify(viewer, status.mentions.create!(account: viewer), :mention)
    end
  end

  def mentioned_recently?(viewer, person)
    since = Mastodon::Snowflake.id_at(BATCH_LIFETIME.ago, with_random: false)
    Mention.joins(:status).exists?(account: viewer, statuses: { account_id: person.id, id: since.. })
  end

  def notify_post_events(viewer, followed, own_post)
    posts = @posts.select { |post| followed.include?(post.account) }

    posts.last(2).each { |post| notify(viewer, post, :status) }
    notify(viewer, quote(followed.last, own_post), :quote) if own_post.distributable?

    edited = posts.first
    edited.update_columns(edited_at: Time.now.utc)
    boost(viewer, edited)
    notify(viewer, edited, :update)

    end_poll(viewer, posts.filter_map(&:preloadable_poll).first)
  end

  def end_poll(viewer, poll)
    return if poll.nil?

    poll.reload
    PollVote.create!(account: viewer, poll: poll, choice: 0) unless poll.expired? || poll.voted?(viewer)
    poll.reload.update_columns(expires_at: 1.minute.ago) if viewer == @viewers.last
    notify(viewer, poll, :poll)
  end

  def notify_collection(viewer)
    owner      = @people.first
    collection = owner.collections.first || owner.collections.create!(
      name: 'People to test with',
      description: 'Test collection.',
      local: true,
      sensitive: false,
      discoverable: true
    )

    (@people[1..6] + [viewer]).each do |member|
      item = collection.collection_items.find_by(account: member) ||
        collection.collection_items.create!(account: member, state: :accepted)
      notify(viewer, item, :added_to_collection) if member == viewer
    end
  end

  def request_follows(viewer, requesters)
    requesters.each do |person|
      next if person.following?(viewer)

      request = FollowRequest.find_or_create_by!(account: person, target_account: viewer)
      notify(viewer, request, :follow_request)
    end
  end

  def request_notification(viewer, stranger)
    return if NotificationRequest.exists?(account: viewer, from_account: stranger)

    status = write_status(stranger, "@#{viewer.username} a mention that waits in filtered notifications.")
    notify(viewer, status.mentions.create!(account: viewer), :mention, filtered: true)
    NotificationRequest.create!(account: viewer, from_account: stranger, last_status: status)
  end

  def fill_conversations(viewer, senders)
    senders.each do |person|
      next if AccountConversation.exists?(account: viewer, participant_account_ids: [person.id])

      status = write_status(person, "@#{viewer.username} a private test message.", visibility: :direct)
      status.mentions.create!(account: viewer)
      AccountConversation.add_status(viewer, status)
    end
  end

  def fill_saved(viewer, followed)
    @posts.first(6).each { |post| Bookmark.find_or_create_by!(account: viewer, status: post) }
    @posts.first(4).each { |post| favourite(viewer, post) }

    Tag.where(name: TAGS.first(5)).find_each { |tag| TagFollow.find_or_create_by!(account: viewer, tag: tag) }

    list = viewer.owned_lists.find_or_create_by!(title: LIST_TITLE)
    followed.each do |person|
      ListAccount.find_or_create_by!(list: list, account: person)
      FeedManager.instance.merge_into_list(person, list)
    end
  end

  def fill_feeds(viewer, followed)
    ids     = followed.map(&:id)
    entries = @posts.select { |post| ids.include?(post.account_id) }
    entries += Status.where(account_id: ids, reblog_of_id: @posts.map(&:id)).to_a

    entries.sort_by(&:id).each { |status| FeedManager.instance.push_to_home(viewer, status) }
  end

  # RankedHomeFeed is a fork feature, plain upstream has no For you
  def fill_for_you(viewer)
    return unless Rails.root.join('app', 'models', 'ranked_home_feed.rb').exist?

    %w(affinity following interests).each { |part| Rails.cache.delete("ranked_home_feed:#{part}:#{viewer.id}") }
    [false, true].each { |discover| RankedHomeFeed.new(viewer, discover: discover).recompute! }
  end

  def refresh_suggestions
    AccountSummary.refresh
    FollowRecommendation.refresh
  end
end

TestContentSeeder.new.run
