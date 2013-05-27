all : Server RemoteHandler

Server : $(shell find -name "*.hs")
	$(GHC) ghc $@.hs -O --make -threaded

RemoteHandler : $(shell find -name "*.hs")
	$(GHC) ghc $@.hs -O --make -threaded
