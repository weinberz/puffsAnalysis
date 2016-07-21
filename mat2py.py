import argparse
import os.path as op
import sys

import h5py
import numpy as np


# mat2py imports params from the MATLAB struct specified by mfilepath, saves it as .npy in savedir and returns it 
# Params are used for classification; the first must always be the class variable e.g. (isPuff)
# MATLAB struct must be saved as v7.3

def mat2py(mfilepath, params, savedir):

	try:
		# Imports MATLAB struct and retrieves tracks 
		f = h5py.File(mfilepath,'r')
		gp1 = f.get('tracks')

		for p in params:
			# data is an ndarray of values for p for all tracks
			data = [gp1[element[0]][:] for element in gp1[p]]

			# arr is built one param at a time to contain all params for all tracks
			if p == params[0]:
				arr = np.array(data)
			else:
				arr = np.hstack((arr,data))

		# Convert arr from ndarray to structured array to store parameter names 
		x = np.core.records.fromarrays((np.squeeze(arr)).transpose(), names = ','.join(params))

		f.close()
		np.save(op.join(savedir, op.splitext(op.basename(mfilepath))[0]), x)
		return x

	except OSError:
		print("Woops, old matlab format. This will fail.")
		return

if __name__ == "__main__":
	parser = argparse.ArgumentParser(description="Convert .mat files to numpy arrays for use with randomforest.py")
	parser.add_argument("matfile", help="The file to be parsed and trained from")
	parser.add_argument("fields", nargs="+", help="Field(s) to extract from .mat file")
	args = parser.parse_args()

	mat2py(args.matfile, args.fields, op.dirname(args.matfile))