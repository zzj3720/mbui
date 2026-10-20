for k in 1 2 3; do for v in base lay new; do (cd $v && bash scripts/render_android.sh run 2>&1 | grep -a 'timed' | sed "s/^/AB $v $k: /"); done; done
