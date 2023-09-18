# Temporary replacement for stories/feed
# we want to create a base feed controller that does the following:
# 1. We have a base class Articles::Feeds::BaseFeedQuery that checks for published and maybe orders accordingly
# 2. if we are in the following path then it calls Articles::Feed::Following which returns articles that are followed.
# 4. if we have a tag then it will amend those passed in articles accordingly from Articles::Feeds::FilterByTagQuery
# (although this seems unused)
# 3. if we have a timeframe then it will amend those passed in articles accordingly from Articles
# Articles::Feed::Timeframes::Latest, Articles::Feed:Timeframes::Top, Articles::Feed::Timeframes::Recommended
# 4. if we have a signed in user then

# Still to implement:
# A general way to incorporate hidden tags in the feeds.
# Think about the performance of the queries.
# Need to think about event tracking for the feeds.
# Not show following for signed out users + amend the feed to work with explore for signed out users
# ?? Biggest question mark here is the Variant Query (hidden tags)
# Change relevant to recommended

# Random Thoughts:
# - We need an “empty state” for the feed
# - we still want hidden-tagged content to appear when searching or /tagname ? I’m not sure on adding to tag feeds at the moment,
# but its definitely not part of this work. I'm unsure of what you mean by toggle-able in this instance.
# - Currently there is no /relevant but it would be nice for there to be a /explore  separate to / which selects explore by
# default (unless the user profile overrides this)
# - ? Might need to amend analytics????
# - ? Following will not show up on signed out feed?
# - ? We’re messing with the url, may be useful to rename some more appropriately ?
# - ? Caching impacts ?
# - ? How does active record work, if we look at the articles tag feed service then we seem t be executing the query rather than building it up and executing it at the end.

# /recommended
# /latest
# /top/week
# /top/month
# /top/year
# /top/infinity

class FeedsController < ApplicationController
  respond_to :json

  def show
    @page = (params[:page] || 1).to_i

    @stories = assign_feed_posts
    add_pinned_article
  end

  private

  def add_pinned_article
    return if params[:timeframe].present?

    pinned_article = PinnedArticle.get
    return if pinned_article.nil? || @stories.detect { |story| story.id == pinned_article.id }

    @stories.prepend(pinned_article.decorate)
  end

  def assign_feed_posts
    articles = nil

    if params[:feed_type] == "following"
      followed_articles = Articles::Feeds::Following.call(user: current_user)
      # unnecessary but used for verbosity at the moment
      articles = followed_articles
    end

    posts = if params[:timeframe].in?(Timeframe::FILTER_TIMEFRAMES)
              timeframe_feed(articles)
            elsif params[:timeframe] == Timeframe::LATEST_TIMEFRAME
              latest_feed(articles)
            elsif user_signed_in?
              signed_in_base_feed(articles)
            else
              signed_out_base_feed
            end

    ArticleDecorator.decorate_collection(posts)
  end

  def signed_in_base_feed(articles)
    feed = if Settings::UserExperience.feed_strategy == "basic"
             articles = Articles::Feeds::BaseFeedQuery.call(articles: articles)
             Articles::Feeds::Basic.new(articles: articles, user: current_user, page: @page, tag: params[:tag])
           # [Ridhwana]: possibly need to filter by base and then following tags
           else
             Articles::Feeds.feed_for(
               user: current_user,
               controller: self,
               page: @page,
               tag: params[:tag],
               number_of_articles: 35,
             )
           end
    Datadog::Tracing.trace("feed.query",
                           span_type: "db",
                           resource: "#{self.class}.#{__method__}",
                           tags: { feed_class: feed.class.to_s.dasherize }) do
      # Hey, why the to_a you say?  Because the
      # LargeForemExperimental has already done this.  But the
      # weighted strategy has not.  I also don't want to alter the
      # weighted query implementation as it returns a lovely
      # ActiveRecord::Relation.  So this is a compromise.
      feed.more_comments_minimal_weight_randomized.to_a
    end
  end

  # [Ridhwana]: ?? When do we ever get here? Signed out feed is server side rendered. Haven't tackled it as yet.
  def signed_out_base_feed(_articles)
    feed = if Settings::UserExperience.feed_strategy == "basic"
             Articles::Feeds::Basic.new(user: nil, page: @page, tag: params[:tag])
           else
             Articles::Feeds.feed_for(
               user: current_user,
               controller: self,
               page: @page,
               tag: params[:tag],
               number_of_articles: 25,
             )
           end
    Datadog::Tracing.trace("feed.query",
                           span_type: "db",
                           resource: "#{self.class}.#{__method__}",
                           tags: { feed_class: feed.class.to_s.dasherize }) do
      # Hey, why the to_a you say?  Because the
      # LargeForemExperimental has already done this.  But the
      # weighted strategy has not.  I also don't want to alter the
      # weighted query implementation as it returns a lovely
      # ActiveRecord::Relation.  So this is a compromise.
      feed.default_home_feed(user_signed_in: false).to_a
    end
  end

  # Same comments apply for latest feed
  def timeframe_feed(articles)
    # [Ridhwana]: It doesnt seem like we need articles_filtered_by_tag because it doesnt match existing behaviour
    # in our application.
    articles_filtered_by_tag = Articles::Feeds::FilterByTagQuery.call(tag: params[:tag], articles: articles)
    # [Ridhwana]: we could add this Base class call in Articles::Feeds::Timeframe?
    articles = Articles::Feeds::BaseFeedQuery.call(articles: articles_filtered_by_tag)
    articles = Articles::Feeds::FilterOutHiddenTagsQuery.call(articles: articles, user: current_user)
    Articles::Feeds::Timeframe.call(params[:timeframe], articles: articles, page: @page)
  end

  def latest_feed(articles)
    Articles::Feeds::Latest.call(articles: articles, page: @page, tag: params[:tag], user: current_user)
  end
end