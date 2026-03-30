#
# Makefile
# c0r73x
#

.PHONY: yue
all: yue

yue:
	@mkdir -p ./lua &> /dev/null
	@yue -s -m -t /tmp/yue ./yue
	@cp -r /tmp/yue/* ./lua
	@rm -rf /tmp/yue

debug:
	@mkdir -p ./lua &> /dev/null
	@yue -s -m -t ./lua ./yue

# vim:ft=make
