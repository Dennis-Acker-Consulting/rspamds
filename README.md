mkdir rspamd.build <br>
cd rspamd.build<br>
cmake ../rspamd -DENABLE_HYPERSCAN=ON -DENABLE_LUAJIT=ON -DCMAKE_BUILD_TYPE=RelWithDebuginfo<br>
make<br>
sudo make install<br>

------------------------------------------------

export RSPAMD_VERSION=3.7.3 # set this to desired Rspamd version
git clone -b ${RSPAMD_VERSION} https://github.com/rspamd/rspamd.git
cd rspamd
sed -i s/\(.*\)/\(${RSPAMD_VERSION}\)/ debian/changelog
sed -i s/quilt/native/ debian/source/format
sudo apt install devscripts
mk-build-deps
sudo bash -c "dpkg -i rspamd-build-deps_${RSPAMD_VERSION}_*.deb && apt install -f -y"
debuild -us -uc
sudo "dpkg -i ../rspamd_${RSPAMD_VERSION}_*.deb"