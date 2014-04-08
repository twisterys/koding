package populartopic

import (
	"encoding/json"
	"fmt"
	"socialapi/config"
	"socialapi/models"
	"time"

	"github.com/koding/logging"
	"github.com/koding/redis"
	"github.com/koding/worker"
	"github.com/streadway/amqp"
)

var (
	PopularTopicKey = "populartopic"
)

type Action func(*PopularTopicsController, *models.ChannelMessageList) error

type PopularTopicsController struct {
	routes map[string]Action
	log    logging.Logger
	redis  *redis.RedisSession
}

func (t *PopularTopicsController) DefaultErrHandler(delivery amqp.Delivery, err error) {
	t.log.Error("an error occured putting message back to queue", err)
	// multiple false
	// reque true
	delivery.Nack(false, true)
}

func NewPopularTopicsController(log logging.Logger, redis *redis.RedisSession) *PopularTopicsController {
	ffc := &PopularTopicsController{
		log:   log,
		redis: redis,
	}

	routes := map[string]Action{
		"channel_message_list_created": (*PopularTopicsController).MessageSaved,
		"channel_message_list_deleted": (*PopularTopicsController).MessageDeleted,
	}

	ffc.routes = routes
	return ffc
}

func (f *PopularTopicsController) HandleEvent(event string, data []byte) error {
	f.log.Debug("New Event Recieved %s", event)
	handler, ok := f.routes[event]
	if !ok {
		return worker.HandlerNotFoundErr
	}

	cml, err := mapMessage(data)
	if err != nil {
		return err
	}

	res, err := f.isEligible(cml)
	if err != nil {
		return err
	}

	// filter messages here
	if !res {
		return nil
	}

	return handler(f, cml)
}

func (f *PopularTopicsController) MessageSaved(data *models.ChannelMessageList) error {
	incrementedVal, err := f.redis.SortedSetIncrBy(GetWeeklyKey(data), 1, data.MessageId)
	if err != nil {
		return err
	}

	incrementedVal, err = f.redis.SortedSetIncrBy(GetMonthlyKey(data), 1, data.MessageId)
	if err != nil {
		return err
	}

	return nil
}

func (f *PopularTopicsController) MessageDeleted(data *models.ChannelMessageList) error {
	incrementedVal, err := f.redis.SortedSetIncrBy(GetWeeklyKey(data), -1, data.MessageId)
	if err != nil {
		return err
	}

	incrementedVal, err = f.redis.SortedSetIncrBy(GetMonthlyKey(data), -1, data.MessageId)
	if err != nil {
		return err
	}

	return nil
}

func GetRedisPrefix() string {
	return fmt.Sprintf(
		"%s:%s",
		config.Get().Environment,
		PopularTopicKey,
	)
}

func GetWeeklyKey(cml *models.ChannelMessageList) string {
	weekNumber := 0
	year := 2014

	if !cml.AddedAt.IsZero() {
		_, weekNumber = cml.AddedAt.ISOWeek()
		year, _, _ = cml.AddedAt.UTC().Date()
	} else {
		// no need to convert it to UTC
		_, weekNumber = time.Now().ISOWeek()
		year, _, _ = time.Now().UTC().Date()

	}

	dateKey := fmt.Sprintf(
		"%s:%d:%d",
		"weekly",
		year,
		weekNumber,
	)
	return dateKey
}

func GetMonthlyKey(cml *models.ChannelMessageList) string {
	var month time.Month
	year := 2014

	if !cml.AddedAt.IsZero() {
		year, month, _ = cml.AddedAt.UTC().Date()
	} else {
		year, month, _ = time.Now().UTC().Date()
	}

	dateKey := fmt.Sprintf(
		"%s:%d:%d",
		"monthly",
		year,
		int(month),
	)

	return dateKey
}

func mapMessage(data []byte) (*models.ChannelMessageList, error) {
	cm := models.NewChannelMessageList()
	if err := json.Unmarshal(data, cm); err != nil {
		return nil, err
	}

	return cm, nil
}

func (f *PopularTopicsController) isEligible(cml *models.ChannelMessageList) (bool, error) {
	// return true, nil
	if cml.ChannelId == 0 {
		f.log.Notice("ChannelId is not set for Channel Message List id: %d", cml.Id)
		return false, nil
	}

	c, err := fetchChannel(cml.ChannelId)
	if err != nil {
		return false, err
	}

	if c.TypeConstant != models.Channel_TYPE_TOPIC {
		return false, nil
	}

	return true, nil
}

// todo add caching here
func fetchChannel(channelId int64) (*models.Channel, error) {
	c := models.NewChannel()
	c.Id = channelId
	if err := c.Fetch(); err != nil {
		return nil, err
	}

	return c, nil
}
