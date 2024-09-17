mkdir rspamd.build <br>
cd rspamd.build<br>
cmake ../rspamd -DENABLE_HYPERSCAN=ON -DENABLE_LUAJIT=ON -DCMAKE_BUILD_TYPE=RelWithDebuginfo<br>
make<br>
sudo make install<br>
<a href="https://rspamd.com/downloads.html">https://rspamd.com/downloads.html</a>
------------------------------------------------
