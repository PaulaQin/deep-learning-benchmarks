require 'sys'
require 'optim'
require 'cutorch'


local opts = require 'opts'
local opt = opts.parse(arg)

-- require 'fbcunn'
-- require 'nnbhwd' -- not compiling anymore, file an issue
local nets = {}
nets[#nets+1] = require 'alexnet'
-- nets[#nets+1] = require 'overfeat'
-- nets[#nets+1] = require 'vgg_a'
--nets[#nets+1] = require 'googlenet'

local libs = {}
-- libs[#libs+1] = {fbnn.SpatialConvolution, cudnn.SpatialMaxPooling, cudnn.ReLU, 'BDHW', 'fbnn'}
-- libs[#libs+1] = {nn.SpatialConvolutionMM, nn.SpatialMaxPooling, nn.ReLU, 'BDHW', 'nn'}
-- libs[#libs+1] = {nn.SpatialConvolutionBHWD, nn.SpatialMaxPoolingBHWD, nn.ReLU, 'BHWD', 'nnBHWD'}

if opt.deviceId >= 0 then
   require 'cunn'
   require 'cudnn'
   cudnn.benchmark = true -- run manual auto-tuner provided by cudnn
   cudnn.verbose = false
   cutorch.setDevice(opt.deviceId+1)
   print('Running on device: ' .. cutorch.getDeviceProperties(cutorch.getDevice()).name)
   libs[#libs+1] = {cudnn.SpatialConvolution, cudnn.SpatialMaxPooling, cudnn.ReLU, 'BDHW', 'cudnn'}
else
   require 'nn'
   libs[#libs+1] = {nn.SpatialConvolution, nn.SpatialMaxPooling, nn.ReLU, 'BDHW', 'nn'}
end

steps = opt.nIterations-- nb of steps in loop to average perf
nDryRuns = opt.nEpochs 

function makeInput(config, size)
   local layout = config[4]
   local osize
   if layout == 'BDHW' then
      osize = size
   elseif layout == 'DHWB' then
      osize = {size[2],size[3],size[4],size[1]}
   elseif layout == 'BHWD' then
      osize = {size[1], size[3], size[4], size[2]}
   end
   return torch.randn(torch.LongStorage(osize))
end

for i=1,#nets do
   for j=1,#libs do
      collectgarbage()
      local model,model_name,size = nets[i](libs[j])
      local paramx, paramdx = model:getParameters()
      local ax, adx         = model:parameters()
      print('Model Parameters: ', paramx:nElement())
      print('All shape: ', ax)

      size[1] = opt.batchSize
      local input
      if opt.deviceId >= 0 then
          model=model:cuda()
          input = makeInput(libs[j],size):cuda()
      else
          input = makeInput(libs[j],size)
      end
      local lib_name = libs[j][5]
      print('ModelType: ' .. model_name, 'Kernels: ' .. lib_name,
            'Input shape: ' .. input:size(1) .. 'x' .. input:size(2) ..
               'x' .. input:size(3) .. 'x' .. input:size(4))

      -- dry-run
      for i=1,nDryRuns do
         model:zeroGradParameters()
         local output = model:updateOutput(input)
         local gradInput = model:updateGradInput(input, output)
         model:accGradParameters(input, output)
         cutorch.synchronize()
         collectgarbage()
      end

      local tmf, tmbi, tmbg
      sys.tic()
      for t = 1,steps do
         output = model:updateOutput(input)
      end
      cutorch.synchronize()
      tmf = sys.toc()/steps
      print(string.format("%-30s %25s %10.2f", lib_name, ':updateOutput():', tmf*1000))

      collectgarbage()
      sys.tic()
      for t = 1,steps do
         model:updateGradInput(input, output)
      end
      cutorch.synchronize()
      tmbi = sys.toc()/steps
      print(string.format("%-30s %25s %10.2f", lib_name, ':updateGradInput():', tmbi*1000))

      collectgarbage()
      sys.tic()
      local ok = 1
      for t = 1,steps do
         ok = pcall(function() model:accGradParameters(input, output) model:updateParameters(0.01) end)
      end
      cutorch.synchronize()
      tmbg = sys.toc()/steps
      if not ok then
         print(string.format("%-30s %25s %s", lib_name, ':accGradParameters():', 'FAILED!'))
      else
         print(string.format("%-30s %25s %10.2f", lib_name, ':accGradParameters():', tmbg*1000))
      end
      print(string.format("%-30s %25s %10.2f", lib_name, ':Forward:', (tmf)*1000))
      print(string.format("%-30s %25s %10.2f", lib_name, ':Backward:', (tmbi+tmbg)*1000))
      print(string.format("%-30s %25s %10.2fms", lib_name, ':TOTAL:', (tmf+tmbi+tmbg)*1000))
      print(string.format(" | Epoch: [][]    Time %10.6f", (tmf+tmbi+tmbg)))
      print()
   end
end

print('')
