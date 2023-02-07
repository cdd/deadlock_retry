DOCKERFILE=Dockerfile
DOCKER=docker
APPLICATION=deadlock_retry

# Note: This is more of a base for all our Ruby apps
DOCKER_IMAGE_NAME=$(APPLICATION)
DOCKER_IMAGE_VERSION=latest
DOCKER_IMAGE=$(DOCKER_IMAGE_NAME):$(DOCKER_IMAGE_VERSION)
DOCKER_BUILD_ARGS=--build-arg application_name=$(DOCKER_IMAGE_NAME)
DEVELOPMENT_VOLUMES=-v $(PWD)/:/tmp/src/$(APPLICATION) -w /tmp/src/$(APPLICATION)

default: image

clean:
	-$(DOCKER) rmi $(DOCKER_IMAGE)

remove_pids:
	rm -rf tmp/pids

image: remove_pids
	$(DOCKER) build --file $(DOCKERFILE) --rm=true -t $(DOCKER_IMAGE) $(DOCKER_BUILD_ARGS) .

run: image
	rm -f tmp/pids/server.pid
	$(DOCKER) run --rm=true -it -e RAILS_ENV=development $(DEVELOPMENT_VOLUMES) $(LINKS) -p 3000:3000 $(DOCKER_IMAGE) -b 0.0.0.0

server: image
	$(DOCKER) run --rm=true -it -e RAILS_ENV=development $(ENVS) $(DEVELOPMENT_VOLUMES) $(LINKS) -p 3000:3000 $(DOCKER_IMAGE) rails s -b 0.0.0.0

shell: image
	$(DOCKER) run --rm=true -it $(ENVS) $(DEVELOPMENT_VOLUMES) $(LINKS) $(DOCKER_IMAGE) bash

guard: image
	$(DOCKER) run --rm=true -it -e RAILS_ENV=test $(ENVS) $(DEVELOPMENT_VOLUMES) $(LINKS) $(DOCKER_IMAGE) bash -c "gem install guard guard-minitest && guard"

test: brakeman
	$(DOCKER) run --rm=true -t -e RAILS_ENV=test $(DEVELOPMENT_VOLUMES) $(LINKS) $(DOCKER_IMAGE) rake

brakeman: image
	$(DOCKER) run --rm -v "$(PWD)":/code presidentbeef/brakeman --color --force
