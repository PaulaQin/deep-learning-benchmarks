import numpy as np
import sys
featDim = 224 * 224 * 3
labDim = 1000
totalCount =  int(sys.argv[1]) * 40

def createFakeData(count):
    features = np.random.randn(count, featDim)
    labels = np.random.randint(0, labDim, size=(count, 1))
    return features, labels

f, l = createFakeData(totalCount)

np.savetxt(r'./imagenet_data.txt', np.hstack((l, f)), fmt='%d' + ' %f4' * featDim)

