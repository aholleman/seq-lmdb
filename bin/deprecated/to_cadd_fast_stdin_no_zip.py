from __future__ import print_function
import gzip
import csv
import sys
import shutil
import time
import cStringIO
from tempfile import NamedTemporaryFile
import logging

def rw_file(debug):
  out_accum = ''
  score_accum = []
  pos_count = 0
  write_every = 0
  

  #TODO: open with gzip if perf ok, as gzip should pass through to open
  #non-zipped files 
  #with open(out_path, 'wt') as wobj:

    #writer = csv.writer(wobj,delimiter='\t')

  for _ in xrange(2): #skip headers
    next(sys.stdin)
  
  for row in sys.stdin:

    row = row.strip().split('\t');

    if pos_count == 0:
      #save chrom,pos,ref,phred
      score_accum = [row[0],row[1],row[2],row[5]]
    elif pos_count <= 2:
      #push the next phred
      score_accum.append(row[5])    
      
      if pos_count == 2: #3 scores accumulated'
        pos_count = 0
        out_accum+="\t".join(score_accum) + "\n";
        if write_every >= 1e8:
          if debug:
            logging.info("\nWe think we found all 3 scores, writing to stdout")
            logging.info(score_accum)
          sys.stdout.write(out_accum);
          write_every = 0
          
          #hopefully gc cleans up old score_accum references upon del
          out_accum = ''; 
        continue

    elif pos_count > 2:
      logging.error("Error, somehow got more than pos_count 2, exiting")
      sys.exit(0)

    pos_count+=1
    write_every +=1

  else: #eof
    if debug:
      logging.info("\nWe reached the end of the file, writing remainder to stdout")
    sys.stdout.write(out_accum);

def main():
  usage = "\n\n\tUsage: to_cadd.py debug [0,1]"
    
  debug = int(sys.argv[1]) if len(sys.argv) > 1 else 0
  
  if debug:
    logging.basicConfig(filename='./to_cadd.log',level=logging.DEBUG)
    start = time.time()
  rw_file(debug);
  if debug:
    logging.info("Finished in %f seconds" %(time.time()-start) )

main()