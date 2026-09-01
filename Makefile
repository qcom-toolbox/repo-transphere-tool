export THEOS_PACKAGE_SCHEME = rootless
export FINALPACKAGE = 1

ARCHS = arm64
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = RepoTransphereTool

RepoTransphereTool_FILES = $(wildcard *.m)
RepoTransphereTool_FRAMEWORKS = UIKit Foundation MobileCoreServices UniformTypeIdentifiers
RepoTransphereTool_CFLAGS = -fobjc-arc -Wall
RepoTransphereTool_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
